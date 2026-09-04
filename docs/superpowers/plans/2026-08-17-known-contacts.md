# Known Contacts Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a per-site, private contact store (`Config/contacts.json`) with a manual
CRUD UI, plus an opt-in Contacts.framework matching scan that suggests linking a system
contact to an existing entry or promoting a not-yet-added ActivityPub follower to a
contact — per the approved design in
[`docs/superpowers/specs/2026-08-17-known-contacts-design.md`](../specs/2026-08-17-known-contacts-design.md)
(issue #966).

**Architecture:** A new `AnglesiteCore` persistence type (`ContactStore`, JSON envelope,
mirrors `ActorProfileCache`) and pure matching logic (`ContactsMatcher`) sit behind a
platform-guarded `Contacts.framework` adapter (`SystemContactsProvider`, mirrors
`FoundationModelAssistant`'s `#if canImport(...)` pattern). `AnglesiteApp` wires these
into the existing `MainPaneMode`/`SiteWindowModel` main-pane pattern (`FollowersModel` is
the closest precedent) and a `WebsiteCommands` menu item.

**Tech Stack:** Swift 6.4, SwiftUI, `Contacts.framework` (macOS only, `#if
canImport(Contacts)`-guarded), Swift Testing (`@Suite`/`@Test`/`#expect`).

## Global Constraints

- Toolchain: Xcode 27+ / Swift 6.4. `xcode-select -p` must point at an Xcode 27 install
  (verified already true in this worktree: `/Applications/Xcode-beta.app/Contents/Developer`).
- If `Anglesite.xcodeproj` is missing or stale (e.g. `project.yml` changed since it was
  generated), run `xcodegen generate` before building — see `CLAUDE.md` ▸ "Worktrees".
- Every new user-facing string literal (`Text`, `Button`, `Label`, etc.) needs a matching
  key in `Sources/AnglesiteApp/Localizable.xcstrings`, or `scripts/check-localization-catalog.sh`
  fails CI (#811). New keys are added as empty entries (`"Key" : {\n\n},`) — no Xcode IDE
  session is required for this file.
- A corrupt/owner-curated data file (`contacts.json`) must throw on load, never silently
  discard — this is a deliberate departure from `ActorProfileCache`'s "cache, discard
  silently" posture; see the design doc §3.
- Contacts permission is requested only on explicit user action ("Find in Contacts…"),
  never at launch or site open.
- Manual contact CRUD (add/edit/delete) must work with zero dependency on Contacts.framework
  or its permission.

---

### Task 1: `Contact` model and `ContactStore` persistence

**Files:**
- Create: `Sources/AnglesiteCore/Contact.swift`
- Create: `Sources/AnglesiteCore/ContactStore.swift`
- Test: `Tests/AnglesiteCoreTests/ContactStoreTests.swift`

**Interfaces:**
- Consumes: nothing (new subsystem).
- Produces:
  - `public struct Contact: Codable, Equatable, Sendable, Identifiable` with `id: UUID`,
    `me: URL`, `displayName: String`, `addedDate: Date`, `linkedActor: URL?`,
    `linkedFeed: URL?`, and `init(id: UUID = UUID(), me: URL, displayName: String,
    addedDate: Date = Date(), linkedActor: URL? = nil, linkedFeed: URL? = nil)`.
  - `func normalizedIdentityKey(for url: URL) -> String` (internal, `AnglesiteCore`-module
    visible) — later tasks (`ContactsMatcher` in Task 2) reuse this exact function.
  - `public actor ContactStore` with `init(configDirectory: URL, fileManager: FileManager
    = .default)`, `func load() throws -> [Contact]`, `func add(_ contact: Contact) throws`,
    `func update(_ contact: Contact) throws`, `func remove(id: UUID) throws`,
    `func knownMeURLs() throws -> Set<String>`, and `public static let filename = "contacts.json"`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/ContactStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ContactStore")
struct ContactStoreTests {
    private static func makeConfigDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContactStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func contact(
        me: String = "https://alice.example", name: String = "Alice"
    ) -> Contact {
        Contact(
            me: URL(string: me)!, displayName: name,
            addedDate: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("returns empty when no file exists yet")
    func returnsEmptyForMissingFile() async throws {
        let directory = try Self.makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContactStore(configDirectory: directory)
        #expect(try await store.load() == [])
    }

    @Test("round-trips a contact through add and load")
    func roundTrips() async throws {
        let directory = try Self.makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContactStore(configDirectory: directory)
        let contact = Self.contact()
        try await store.add(contact)

        let loaded = try await store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == contact.id)
        #expect(loaded.first?.displayName == "Alice")
    }

    @Test("adding a contact with a matching me URL replaces the existing entry")
    func addReplacesOnMatchingIdentity() async throws {
        let directory = try Self.makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContactStore(configDirectory: directory)
        try await store.add(Self.contact(me: "https://alice.example", name: "Alice"))
        try await store.add(Self.contact(me: "https://alice.example/", name: "Alice Renamed"))

        let loaded = try await store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.displayName == "Alice Renamed")
    }

    @Test("update rekeys a contact whose me URL changed")
    func updateRekeys() async throws {
        let directory = try Self.makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContactStore(configDirectory: directory)
        var contact = Self.contact(me: "https://old.example")
        try await store.add(contact)

        contact.me = URL(string: "https://new.example")!
        try await store.update(contact)

        let loaded = try await store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.me.absoluteString == "https://new.example")
    }

    @Test("remove deletes by id")
    func removeDeletes() async throws {
        let directory = try Self.makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContactStore(configDirectory: directory)
        let contact = Self.contact()
        try await store.add(contact)
        try await store.remove(id: contact.id)

        #expect(try await store.load() == [])
    }

    @Test("throws instead of silently discarding a corrupt file")
    func throwsOnCorruptFile() async throws {
        let directory = try Self.makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{ not json".utf8).write(
            to: directory.appendingPathComponent(ContactStore.filename))
        let store = ContactStore(configDirectory: directory)

        await #expect(throws: (any Error).self) {
            try await store.load()
        }
    }

    @Test("knownMeURLs normalizes scheme and trailing slash")
    func knownMeURLsNormalizes() async throws {
        let directory = try Self.makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContactStore(configDirectory: directory)
        try await store.add(Self.contact(me: "https://alice.example/"))

        let known = try await store.knownMeURLs()
        #expect(known.contains(normalizedIdentityKey(for: URL(string: "http://alice.example")!)))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `swift test --package-path . --filter ContactStoreTests`
Expected: FAIL — `Contact`/`ContactStore`/`normalizedIdentityKey` don't exist yet.

- [ ] **Step 3: Write `Contact.swift`**

```swift
import Foundation

/// A person the site owner knows, stored privately per site (#966). Distinct from the public
/// `member` content type (`ContentTypeRegistry.swift`) — this is never published.
public struct Contact: Codable, Equatable, Sendable, Identifiable {
    /// Stable identity for SwiftUI list diffing and lookup. Not one of the issue's three literal
    /// fields (`me`, `displayName`, `addedDate`) — needed because `me` itself is editable, so it
    /// can't double as a stable key the way `FollowerRow.id` uses `actor.absoluteString`.
    public let id: UUID
    /// The person's canonical identity URL — their own website, in the IndieAuth `me` sense.
    public var me: URL
    public var displayName: String
    public let addedDate: Date
    /// The ActivityPub actor IRI, set when this contact was promoted from a follower.
    public var linkedActor: URL?
    /// A followed Microsub feed URL. No promotion flow populates this yet (`MicrosubClient` has
    /// no "list followed feeds" endpoint) — settable only via manual edit until one exists.
    public var linkedFeed: URL?

    public init(
        id: UUID = UUID(),
        me: URL,
        displayName: String,
        addedDate: Date = Date(),
        linkedActor: URL? = nil,
        linkedFeed: URL? = nil
    ) {
        self.id = id
        self.me = me
        self.displayName = displayName
        self.addedDate = addedDate
        self.linkedActor = linkedActor
        self.linkedFeed = linkedFeed
    }
}

/// Normalizes a URL for identity comparison: lowercased host, scheme dropped, trailing slash
/// trimmed. Contacts enter `me` and social/website URLs by hand, so two URLs that only differ by
/// http/https or a trailing slash must still compare equal. Shared by `ContactStore` (identity
/// dedup) and `ContactsMatcher` (Task 2, matching against system Contacts).
func normalizedIdentityKey(for url: URL) -> String {
    let host = (url.host ?? "").lowercased()
    var path = url.path
    if path.hasSuffix("/"), path != "/" {
        path.removeLast()
    }
    return host + path
}
```

- [ ] **Step 4: Write `ContactStore.swift`**

```swift
import Foundation

/// Per-site contact store persisted to `<configDirectory>/contacts.json` (#966) — app-owned
/// state that must never enter the site's git repo, alongside `chat-history.jsonl` and
/// `ActorProfileCache`'s file. A full-file JSON envelope (like `ActorProfileCache`), not
/// append-only JSONL (like `ChatHistoryStore`): contacts are edited and deleted, not just
/// appended.
public actor ContactStore {
    public static let filename = "contacts.json"

    private struct Envelope: Codable { let contacts: [Contact] }

    public let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(configDirectory: URL, fileManager: FileManager = .default) {
        self.fileURL = configDirectory.appendingPathComponent(Self.filename)
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// A missing file is the normal first-run state (`[]`, no error). A file that exists but
    /// fails to decode throws instead of discarding silently: unlike `ActorProfileCache` (a
    /// disposable, re-fetchable cache), a contact list is owner-curated data, and silently
    /// showing zero contacts risks the owner believing the list was lost and re-entering it.
    public func load() throws -> [Contact] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }
        let envelope = try decoder.decode(Envelope.self, from: data)
        return envelope.contacts.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    /// Adds a contact, replacing any existing entry with the same `me` identity (comparing via
    /// ``normalizedIdentityKey(for:)``, so `https://x.example` and `https://x.example/` collide).
    public func add(_ contact: Contact) throws {
        var contacts = try load()
        contacts.removeAll {
            normalizedIdentityKey(for: $0.me) == normalizedIdentityKey(for: contact.me)
        }
        contacts.append(contact)
        try write(contacts)
    }

    /// Replaces the contact matching `contact.id`, wherever its `me` moved to — this is the
    /// rekey path for editing an existing entry's URL.
    public func update(_ contact: Contact) throws {
        var contacts = try load()
        contacts.removeAll { $0.id == contact.id }
        contacts.append(contact)
        try write(contacts)
    }

    public func remove(id: UUID) throws {
        var contacts = try load()
        contacts.removeAll { $0.id == id }
        try write(contacts)
    }

    /// Forward-looking hook for #963's authenticated-read allowlist — not called from anywhere
    /// in this feature, but the store is the source of truth #963 will read from.
    public func knownMeURLs() throws -> Set<String> {
        Set(try load().map { normalizedIdentityKey(for: $0.me) })
    }

    private func write(_ contacts: [Contact]) throws {
        let parent = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let data = try encoder.encode(Envelope(contacts: contacts))
        try data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path . --filter ContactStoreTests`
Expected: PASS (7 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/Contact.swift Sources/AnglesiteCore/ContactStore.swift Tests/AnglesiteCoreTests/ContactStoreTests.swift
git commit -m "feat(#966): add per-site Contact model and ContactStore"
```

---

### Task 2: `ContactsMatcher` matching logic

**Files:**
- Create: `Sources/AnglesiteCore/ContactsMatcher.swift`
- Test: `Tests/AnglesiteCoreTests/ContactsMatcherTests.swift`

**Interfaces:**
- Consumes: `Contact`, `normalizedIdentityKey(for:)` (Task 1).
- Produces:
  - `public struct MatchableContact: Sendable, Equatable` with `displayName: String`,
    `urlAddresses: [URL]`, `socialProfileURLs: [URL]`, and a matching memberwise `init`.
  - `public struct MatchSuggestion: Sendable, Equatable` with `candidateURL: URL`,
    `systemContactName: String`, `kind: Kind`, and nested
    `public enum Kind: Sendable, Equatable { case enrichExisting(Contact);
    case promoteToContact }`.
  - `public enum ContactsMatcher` with `static func suggestions(matchableContacts:
    [MatchableContact], existingContacts: [Contact], candidateFollowerURLs: [URL]) ->
    [MatchSuggestion]` — used by `ContactsModel` in Task 4.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/ContactsMatcherTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ContactsMatcher")
struct ContactsMatcherTests {
    private static let aliceMe = URL(string: "https://alice.example")!
    private static let bobActor = URL(string: "https://mastodon.social/users/bob")!

    @Test("suggests enriching an existing contact whose name differs from the system contact")
    func suggestsEnrichment() {
        let existing = Contact(me: Self.aliceMe, displayName: "alice.example")
        let systemContacts = [
            MatchableContact(
                displayName: "Alice Smith", urlAddresses: [Self.aliceMe], socialProfileURLs: [])
        ]

        let suggestions = ContactsMatcher.suggestions(
            matchableContacts: systemContacts, existingContacts: [existing],
            candidateFollowerURLs: [])

        #expect(suggestions.count == 1)
        #expect(suggestions.first?.systemContactName == "Alice Smith")
        #expect(suggestions.first?.kind == .enrichExisting(existing))
    }

    @Test("does not suggest enrichment when the names already match")
    func skipsEnrichmentWhenNamesMatch() {
        let existing = Contact(me: Self.aliceMe, displayName: "Alice Smith")
        let systemContacts = [
            MatchableContact(
                displayName: "Alice Smith", urlAddresses: [Self.aliceMe], socialProfileURLs: [])
        ]

        let suggestions = ContactsMatcher.suggestions(
            matchableContacts: systemContacts, existingContacts: [existing],
            candidateFollowerURLs: [])

        #expect(suggestions.isEmpty)
    }

    @Test("suggests promoting a not-yet-added follower that matches a system contact")
    func suggestsPromotion() {
        let systemContacts = [
            MatchableContact(
                displayName: "Bob Jones", urlAddresses: [], socialProfileURLs: [Self.bobActor])
        ]

        let suggestions = ContactsMatcher.suggestions(
            matchableContacts: systemContacts, existingContacts: [],
            candidateFollowerURLs: [Self.bobActor])

        #expect(suggestions.count == 1)
        #expect(suggestions.first?.systemContactName == "Bob Jones")
        #expect(suggestions.first?.kind == .promoteToContact)
    }

    @Test("does not suggest promoting a follower already added as a contact")
    func skipsPromotionForExistingContact() {
        let existing = Contact(me: Self.bobActor, displayName: "Bob Jones")
        let systemContacts = [
            MatchableContact(
                displayName: "Bob Jones", urlAddresses: [], socialProfileURLs: [Self.bobActor])
        ]

        let suggestions = ContactsMatcher.suggestions(
            matchableContacts: systemContacts, existingContacts: [existing],
            candidateFollowerURLs: [Self.bobActor])

        #expect(suggestions.isEmpty)
    }

    @Test("matches URLs that differ only by scheme and trailing slash")
    func matchesNormalizedURLs() {
        let existing = Contact(me: URL(string: "http://alice.example/")!, displayName: "alice")
        let systemContacts = [
            MatchableContact(
                displayName: "Alice Smith", urlAddresses: [URL(string: "https://alice.example")!],
                socialProfileURLs: [])
        ]

        let suggestions = ContactsMatcher.suggestions(
            matchableContacts: systemContacts, existingContacts: [existing],
            candidateFollowerURLs: [])

        #expect(suggestions.count == 1)
    }

    @Test("produces no suggestions when nothing matches")
    func noMatches() {
        let suggestions = ContactsMatcher.suggestions(
            matchableContacts: [], existingContacts: [], candidateFollowerURLs: [Self.bobActor])
        #expect(suggestions.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `swift test --package-path . --filter ContactsMatcherTests`
Expected: FAIL — `MatchableContact`/`MatchSuggestion`/`ContactsMatcher` don't exist yet.

- [ ] **Step 3: Write `ContactsMatcher.swift`**

```swift
import Foundation

/// One system Contact's matchable identity signals — its display name plus every URL it carries
/// (website fields and social-profile URLs), already extracted from `CNContact` by whichever
/// `ContactsProviding` implementation supplied it (Task 3). Kept independent of
/// `Contacts.framework` types so this file, and its matching logic, stay portable and
/// unit-testable without `CNContactStore`.
public struct MatchableContact: Sendable, Equatable {
    public let displayName: String
    public let urlAddresses: [URL]
    public let socialProfileURLs: [URL]

    public init(displayName: String, urlAddresses: [URL], socialProfileURLs: [URL]) {
        self.displayName = displayName
        self.urlAddresses = urlAddresses
        self.socialProfileURLs = socialProfileURLs
    }
}

/// One suggested link between a system Contact and a known identity URL, surfaced in the
/// Contacts pane's "Find in Contacts…" scan (#966).
public struct MatchSuggestion: Sendable, Equatable {
    public let candidateURL: URL
    public let systemContactName: String
    public let kind: Kind

    public enum Kind: Sendable, Equatable {
        /// A manually-added contact's `me` URL matches a system contact whose name differs —
        /// offer to adopt the system contact's name.
        case enrichExisting(Contact)
        /// A not-yet-added follower's actor URL matches a system contact — offer to add them.
        case promoteToContact
    }

    public init(candidateURL: URL, systemContactName: String, kind: Kind) {
        self.candidateURL = candidateURL
        self.systemContactName = systemContactName
        self.kind = kind
    }
}

/// Pure matching logic (design doc §5) — no I/O, no `Contacts` import, so it runs the same in CI
/// as it does live: given a batch of system contacts and the app's own known identities, produce
/// suggestions in both directions.
public enum ContactsMatcher {
    public static func suggestions(
        matchableContacts: [MatchableContact],
        existingContacts: [Contact],
        candidateFollowerURLs: [URL]
    ) -> [MatchSuggestion] {
        var suggestions: [MatchSuggestion] = []

        for contact in existingContacts {
            guard let match = firstMatch(for: contact.me, in: matchableContacts) else { continue }
            guard match.displayName != contact.displayName else { continue }
            suggestions.append(
                MatchSuggestion(
                    candidateURL: contact.me, systemContactName: match.displayName,
                    kind: .enrichExisting(contact)))
        }

        let existingKeys = Set(existingContacts.map { normalizedIdentityKey(for: $0.me) })
        for followerURL in candidateFollowerURLs {
            guard !existingKeys.contains(normalizedIdentityKey(for: followerURL)) else { continue }
            guard let match = firstMatch(for: followerURL, in: matchableContacts) else { continue }
            suggestions.append(
                MatchSuggestion(
                    candidateURL: followerURL, systemContactName: match.displayName,
                    kind: .promoteToContact))
        }

        return suggestions
    }

    private static func firstMatch(
        for url: URL, in matchableContacts: [MatchableContact]
    ) -> MatchableContact? {
        let key = normalizedIdentityKey(for: url)
        return matchableContacts.first {
            ($0.urlAddresses + $0.socialProfileURLs).contains {
                normalizedIdentityKey(for: $0) == key
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter ContactsMatcherTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ContactsMatcher.swift Tests/AnglesiteCoreTests/ContactsMatcherTests.swift
git commit -m "feat(#966): add ContactsMatcher pure matching logic"
```

---

### Task 3: `ContactsProviding` protocol and `Contacts.framework` adapter

**Files:**
- Create: `Sources/AnglesiteCore/ContactsProviding.swift`

**Interfaces:**
- Consumes: `MatchableContact` (Task 2).
- Produces: `public protocol ContactsProviding: Sendable { func matchableContacts() async
  throws -> [MatchableContact] }`, `public enum ContactsAccessError: Error, Equatable,
  Sendable { case denied }`, and (behind `#if canImport(Contacts)`) `public struct
  SystemContactsProvider: ContactsProviding` with `public init()` and `static func
  matchableContact(from contact: CNContact) -> MatchableContact?`.

**Test strategy**: `matchableContacts()` itself drives a real `CNContactStore`
(`requestAccess`/`enumerateContacts`), which is TCC-gated — a bare `swift test` binary
can't hold the Contacts permission (the same class of problem the sandboxed-binary-probe
precedent solves for App Sandbox), so that thin I/O wrapper is exercised manually in
Task 9's verification pass instead. But the actual per-contact extraction logic —
display name plus every URL/social-profile field — is pure `CNContact` → `MatchableContact`
mapping, and `CNMutableContact`/`CNLabeledValue`/`CNSocialProfile` are plain in-memory
objects: constructing and reading them needs no store access and no TCC permission at
all (verified directly against this worktree's SDK before writing this task — see the
commands below). So that mapping is pulled out into its own `static` function and given
a real test, the same way `FollowerAvatar.dimensionsWithinBound(_:)` is pulled out of an
otherwise-untested view file (`FollowersView.swift`) specifically so it can be tested
without the untestable I/O around it.

Verified compiling (and running, for the non-store parts) against this worktree's SDK
before writing the code below:

```bash
xcrun swiftc -sdk $(xcrun --show-sdk-path --sdk macosx) -target arm64-apple-macos15.0 probe.swift -o probe && ./probe
# name: Alice Smith
# url: https://alice.example
# social url: https://mastodon.social/users/bob
# CNAggregateKeyDescriptor
```

- [ ] **Step 1: Write `ContactsProviding.swift`**

```swift
import Foundation
#if canImport(Contacts)
import Contacts
#endif

/// One system contact's matchable identity signals, plus how to fetch a batch of them. The
/// `Contacts.framework`-backed implementation lives behind `#if canImport(Contacts)` — mirrors
/// `FoundationModelAssistant`'s platform-guarded-framework-inside-a-portable-target pattern — so
/// this protocol itself stays usable from portable code and from tests without ever touching
/// `CNContactStore`.
public protocol ContactsProviding: Sendable {
    /// Requests Contacts access if needed, then returns every system contact's matchable URLs.
    /// Throws ``ContactsAccessError/denied`` if the owner declines the permission prompt.
    func matchableContacts() async throws -> [MatchableContact]
}

public enum ContactsAccessError: Error, Equatable, Sendable {
    case denied
}

#if canImport(Contacts)
/// The real, `CNContactStore`-backed provider. Requests access on first use — never at launch —
/// per the design doc §5's "opt-in per scan" requirement.
public struct SystemContactsProvider: ContactsProviding {
    public init() {}

    public func matchableContacts() async throws -> [MatchableContact] {
        let store = CNContactStore()
        let granted = try await requestAccess(store: store)
        guard granted else { throw ContactsAccessError.denied }
        return try await Task.detached(priority: .utility) {
            try Self.fetchAll(store: store)
        }.value
    }

    private func requestAccess(store: CNContactStore) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// Runs off the calling task (see the `Task.detached` above) because `enumerateContacts`
    /// blocks synchronously over the whole address book.
    private static func fetchAll(store: CNContactStore) throws -> [MatchableContact] {
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactSocialProfilesKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var results: [MatchableContact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            if let matchable = matchableContact(from: contact) {
                results.append(matchable)
            }
        }
        return results
    }

    /// Maps one `CNContact` to its matchable identity signals, or `nil` if it has neither a
    /// usable name nor any URL to match against. Pure — no store access, no I/O — so it's
    /// pulled out of `fetchAll` specifically to be unit-tested directly (see this task's test
    /// strategy note above and `SystemContactsProviderTests`). Not `private`, for the same
    /// testability reason `FollowerAvatar.dimensionsWithinBound(_:)` isn't.
    static func matchableContact(from contact: CNContact) -> MatchableContact? {
        let name = CNContactFormatter.string(from: contact, style: .fullName)
            ?? contact.organizationName
        guard let name, !name.isEmpty else { return nil }
        let urls = contact.urlAddresses.compactMap { URL(string: $0.value as String) }
        let socialURLs = contact.socialProfiles.compactMap { labeled -> URL? in
            let urlString = labeled.value.urlString
            return urlString.isEmpty ? nil : URL(string: urlString)
        }
        guard !urls.isEmpty || !socialURLs.isEmpty else { return nil }
        return MatchableContact(displayName: name, urlAddresses: urls, socialProfileURLs: socialURLs)
    }
}
#endif
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/AnglesiteCoreTests/SystemContactsProviderTests.swift`. The whole file is
guarded by `#if canImport(Contacts)` — on a platform without Contacts (e.g. Linux) it
compiles to nothing, same as `SystemContactsProvider` itself:

```swift
#if canImport(Contacts)
import Testing
import Foundation
import Contacts
@testable import AnglesiteCore

@Suite("SystemContactsProvider matching")
struct SystemContactsProviderTests {
    private static func makeContact(
        givenName: String,
        familyName: String = "",
        urlAddresses: [String] = [],
        socialProfileURLs: [String] = []
    ) -> CNContact {
        let mutable = CNMutableContact()
        mutable.givenName = givenName
        mutable.familyName = familyName
        mutable.urlAddresses = urlAddresses.map {
            CNLabeledValue(label: CNLabelURLAddressHomePage, value: $0 as NSString)
        }
        mutable.socialProfiles = socialProfileURLs.map {
            CNLabeledValue(
                label: CNSocialProfileServiceMastodon,
                value: CNSocialProfile(
                    urlString: $0, username: nil, userIdentifier: nil, service: nil))
        }
        return mutable
    }

    @Test("extracts display name and URL addresses")
    func extractsNameAndURLs() {
        let contact = Self.makeContact(
            givenName: "Alice", familyName: "Smith",
            urlAddresses: ["https://alice.example"])

        let matchable = SystemContactsProvider.matchableContact(from: contact)

        #expect(matchable?.displayName == "Alice Smith")
        #expect(matchable?.urlAddresses == [URL(string: "https://alice.example")!])
    }

    @Test("extracts social profile URLs")
    func extractsSocialProfileURLs() {
        let contact = Self.makeContact(
            givenName: "Bob",
            socialProfileURLs: ["https://mastodon.social/users/bob"])

        let matchable = SystemContactsProvider.matchableContact(from: contact)

        #expect(matchable?.socialProfileURLs == [URL(string: "https://mastodon.social/users/bob")!])
    }

    @Test("returns nil for a contact with no name")
    func returnsNilForNoName() {
        let contact = Self.makeContact(givenName: "", urlAddresses: ["https://example.com"])
        #expect(SystemContactsProvider.matchableContact(from: contact) == nil)
    }

    @Test("returns nil for a contact with no URLs at all")
    func returnsNilForNoURLs() {
        let contact = Self.makeContact(givenName: "Carol")
        #expect(SystemContactsProvider.matchableContact(from: contact) == nil)
    }

    @Test("ignores an empty social profile URL string")
    func ignoresEmptySocialProfileURL() {
        let mutable = CNMutableContact()
        mutable.givenName = "Dana"
        mutable.socialProfiles = [
            CNLabeledValue(
                label: CNSocialProfileServiceTwitter,
                value: CNSocialProfile(
                    urlString: "", username: "dana", userIdentifier: nil, service: "Twitter"))
        ]
        #expect(SystemContactsProvider.matchableContact(from: mutable) == nil)
    }
}
#endif
```

- [ ] **Step 3: Run tests to verify they fail to compile**

Run: `swift test --package-path . --filter SystemContactsProviderTests`
Expected: FAIL — `matchableContact(from:)` isn't `static`/exposed yet (Step 1 already
wrote it above, so run this immediately after Step 1's file is saved but before assuming
it passes; if this worktree's `AnglesiteCore` target doesn't yet build with Step 1's
content in place, fix that first).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter SystemContactsProviderTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Verify the whole target still compiles**

Run: `swift build --package-path . --target AnglesiteCore`
Expected: BUILD SUCCEEDED (compiles both with and without `canImport(Contacts)`; this
worktree's macOS toolchain has Contacts, so `SystemContactsProvider` and its test compile
here).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteCore/ContactsProviding.swift Tests/AnglesiteCoreTests/SystemContactsProviderTests.swift
git commit -m "feat(#966): add ContactsProviding seam and SystemContactsProvider"
```

---

### Task 4: `ContactsModel` (app glue)

**Files:**
- Create: `Sources/AnglesiteApp/ContactsModel.swift`
- Test: `Tests/AnglesiteAppTests/ContactsModelTests.swift`

**Interfaces:**
- Consumes: `Contact`, `ContactStore`, `ContactsProviding`, `ContactsAccessError`,
  `MatchableContact`, `ContactsMatcher`, `MatchSuggestion`, `SystemContactsProvider`
  (Tasks 1–3, `AnglesiteCore`); `CurrentSite` (already exists, `AnglesiteApp`).
- Produces: `@MainActor @Observable final class ContactsModel` with `init(contactsProvider:
  ContactsProviding = SystemContactsProvider())`, `func configure(site: CurrentSite)`,
  `func reload() async`, `func add(me: URL, displayName: String) async`, `func update(_
  contact: Contact) async`, `func remove(_ contact: Contact) async`, `func
  scanForMatches(candidateFollowerURLs: [URL]) async`, `func dismiss(_ suggestion:
  MatchSuggestion)`, `func accept(_ suggestion: MatchSuggestion) async`, and read-only
  state `contacts: [Contact]`, `loadState: LoadState` (`.idle`/`.loaded`/`.corruptFile`),
  `suggestions: [MatchSuggestion]`, `isScanning: Bool`, `scanFailure: ScanFailure?`
  (`.permissionDenied`/`.other(String)`) — used by `ContactsView` (Task 5) and
  `SiteWindowModel` (Task 6).

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteAppTests/ContactsModelTests.swift`:

```swift
import Testing
import Foundation
import AnglesiteCore
@testable import AnglesiteAppCore

@Suite("ContactsModel")
@MainActor
struct ContactsModelTests {
    private static func makeSite() throws -> CurrentSite {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContactsModelTests-\(UUID().uuidString)")
        let config = root.appendingPathComponent("Config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        return CurrentSite(
            id: "site-1", packageURL: root, sourceDirectory: root, configDirectory: config)
    }

    private struct FakeContactsProvider: ContactsProviding {
        var result: Result<[MatchableContact], Error>
        func matchableContacts() async throws -> [MatchableContact] {
            try result.get()
        }
    }

    @Test("loads an empty list for a fresh site")
    func loadsEmptyForFreshSite() async throws {
        let model = ContactsModel(contactsProvider: FakeContactsProvider(result: .success([])))
        model.configure(site: try Self.makeSite())
        await model.reload()

        #expect(model.loadState == .loaded)
        #expect(model.contacts.isEmpty)
    }

    @Test("add then remove round-trips through the store")
    func addAndRemove() async throws {
        let model = ContactsModel(contactsProvider: FakeContactsProvider(result: .success([])))
        model.configure(site: try Self.makeSite())
        await model.reload()

        await model.add(me: URL(string: "https://alice.example")!, displayName: "Alice")
        #expect(model.contacts.count == 1)

        let added = try #require(model.contacts.first)
        await model.remove(added)
        #expect(model.contacts.isEmpty)
    }

    @Test("scanForMatches surfaces a promotion suggestion")
    func scanSurfacesPromotion() async throws {
        let bob = URL(string: "https://mastodon.social/users/bob")!
        let provider = FakeContactsProvider(
            result: .success([
                MatchableContact(
                    displayName: "Bob Jones", urlAddresses: [], socialProfileURLs: [bob])
            ]))
        let model = ContactsModel(contactsProvider: provider)
        model.configure(site: try Self.makeSite())
        await model.reload()

        await model.scanForMatches(candidateFollowerURLs: [bob])

        #expect(model.suggestions.count == 1)
        #expect(model.scanFailure == nil)
    }

    @Test("scanForMatches surfaces permission denial without crashing")
    func scanSurfacesDenial() async throws {
        let provider = FakeContactsProvider(result: .failure(ContactsAccessError.denied))
        let model = ContactsModel(contactsProvider: provider)
        model.configure(site: try Self.makeSite())
        await model.reload()

        await model.scanForMatches(candidateFollowerURLs: [])

        #expect(model.scanFailure == .permissionDenied)
        #expect(model.suggestions.isEmpty)
    }

    @Test("accepting a promotion suggestion adds it as a contact and clears the suggestion")
    func acceptPromotion() async throws {
        let bob = URL(string: "https://mastodon.social/users/bob")!
        let provider = FakeContactsProvider(
            result: .success([
                MatchableContact(
                    displayName: "Bob Jones", urlAddresses: [], socialProfileURLs: [bob])
            ]))
        let model = ContactsModel(contactsProvider: provider)
        model.configure(site: try Self.makeSite())
        await model.reload()
        await model.scanForMatches(candidateFollowerURLs: [bob])
        let suggestion = try #require(model.suggestions.first)

        await model.accept(suggestion)

        #expect(model.contacts.contains { $0.me == bob && $0.displayName == "Bob Jones" })
        #expect(model.suggestions.isEmpty)
    }

    @Test("dismissing a suggestion removes it and it does not resurface until the next scan")
    func dismissSuggestion() async throws {
        let bob = URL(string: "https://mastodon.social/users/bob")!
        let provider = FakeContactsProvider(
            result: .success([
                MatchableContact(
                    displayName: "Bob Jones", urlAddresses: [], socialProfileURLs: [bob])
            ]))
        let model = ContactsModel(contactsProvider: provider)
        model.configure(site: try Self.makeSite())
        await model.reload()
        await model.scanForMatches(candidateFollowerURLs: [bob])
        let suggestion = try #require(model.suggestions.first)

        model.dismiss(suggestion)
        #expect(model.suggestions.isEmpty)

        await model.scanForMatches(candidateFollowerURLs: [bob])
        #expect(model.suggestions.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `swift test --package-path . --filter ContactsModelTests`
Expected: FAIL — `ContactsModel` doesn't exist yet.

- [ ] **Step 3: Write `ContactsModel.swift`**

```swift
import Foundation
import Observation
import AnglesiteCore

/// Drives the Contacts pane (Website ▸ Contacts…, #966): a per-site, private list of known
/// people, plus an opt-in Contacts.framework matching scan. App glue only — persistence and
/// matching logic live in `AnglesiteCore`.
@MainActor
@Observable
final class ContactsModel {
    enum LoadState: Equatable {
        case idle
        case loaded
        /// `ContactStore.load()` threw — the file exists but didn't decode. Surfaced rather than
        /// silently showing an empty list (see `ContactStore`'s doc comment for why).
        case corruptFile
    }

    enum ScanFailure: Equatable {
        case permissionDenied
        case other(String)
    }

    private(set) var contacts: [Contact] = []
    private(set) var loadState: LoadState = .idle
    private(set) var suggestions: [MatchSuggestion] = []
    private(set) var isScanning = false
    private(set) var scanFailure: ScanFailure?

    private var store: ContactStore?
    /// Session-scoped, like `FollowersModel.unreachableActors`: a dismissed suggestion can
    /// resurface on a later scan, which is fine since scans are always owner-initiated.
    private var dismissedSuggestionKeys: Set<String> = []
    private let contactsProvider: ContactsProviding

    init(contactsProvider: ContactsProviding = SystemContactsProvider()) {
        self.contactsProvider = contactsProvider
    }

    /// Records which site this pane reads. Called once per site open, like
    /// `FollowersModel.configure(site:)`. Does not load — `ContactsView`'s `.task` triggers
    /// ``reload()`` the same way `FollowersView`'s `.task` triggers `FollowersModel.load()`.
    func configure(site: CurrentSite) {
        store = ContactStore(configDirectory: site.configDirectory)
    }

    func reload() async {
        guard let store else { return }
        do {
            contacts = try await store.load()
            loadState = .loaded
        } catch {
            contacts = []
            loadState = .corruptFile
        }
    }

    func add(me: URL, displayName: String) async {
        guard let store else { return }
        let contact = Contact(me: me, displayName: displayName)
        try? await store.add(contact)
        await reload()
    }

    func update(_ contact: Contact) async {
        guard let store else { return }
        try? await store.update(contact)
        await reload()
    }

    func remove(_ contact: Contact) async {
        guard let store else { return }
        try? await store.remove(id: contact.id)
        await reload()
    }

    /// Runs one on-demand Contacts.framework scan (Website ▸ Contacts… ▸ "Find in Contacts…").
    /// `candidateFollowerURLs` are the not-yet-added follower actor IRIs to check for the
    /// promote-to-contact direction — the caller (`SiteWindowModel`) is responsible for making
    /// sure Followers has loaded before supplying them.
    func scanForMatches(candidateFollowerURLs: [URL]) async {
        isScanning = true
        scanFailure = nil
        defer { isScanning = false }
        do {
            let matchable = try await contactsProvider.matchableContacts()
            let fresh = ContactsMatcher.suggestions(
                matchableContacts: matchable,
                existingContacts: contacts,
                candidateFollowerURLs: candidateFollowerURLs)
            suggestions = fresh.filter { !dismissedSuggestionKeys.contains(suggestionKey($0)) }
        } catch ContactsAccessError.denied {
            scanFailure = .permissionDenied
        } catch {
            scanFailure = .other("\(error)")
        }
    }

    func dismiss(_ suggestion: MatchSuggestion) {
        dismissedSuggestionKeys.insert(suggestionKey(suggestion))
        suggestions.removeAll { suggestionKey($0) == suggestionKey(suggestion) }
    }

    func accept(_ suggestion: MatchSuggestion) async {
        switch suggestion.kind {
        case .enrichExisting(let contact):
            var updated = contact
            updated.displayName = suggestion.systemContactName
            await update(updated)
        case .promoteToContact:
            await add(me: suggestion.candidateURL, displayName: suggestion.systemContactName)
        }
        dismiss(suggestion)
    }

    private func suggestionKey(_ suggestion: MatchSuggestion) -> String {
        "\(suggestion.candidateURL.absoluteString)|\(suggestion.systemContactName)"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter ContactsModelTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/ContactsModel.swift Tests/AnglesiteAppTests/ContactsModelTests.swift
git commit -m "feat(#966): add ContactsModel"
```

---

### Task 5: `ContactsView`

**Files:**
- Create: `Sources/AnglesiteApp/ContactsView.swift`
- Test: `Tests/AnglesiteAppTests/ContactEditValidationTests.swift`

**Interfaces:**
- Consumes: `ContactsModel` (Task 4); `Contact`, `MatchSuggestion` (`AnglesiteCore`).
- Produces: `struct ContactsView: View` with `init(contacts: ContactsModel,
  candidateFollowerURLs: @escaping () async -> [URL])` — consumed by `SiteWindow.swift`
  in Task 7. Also `enum ContactEditValidation` with `static func validate(displayName:
  String, meText: String) -> Result<(url: URL, displayName: String), String>`.

**Test strategy**: this codebase does not unit-test SwiftUI view bodies (there is no
`FollowersViewTests.swift` either), so `ContactsView`'s layout is verified by compiling
and by the manual run-through in Task 9. But `ContactEditSheet`'s Save button runs real
validation logic (trim, require a name, require a parseable http(s) URL) that has nothing
to do with rendering — so, like `FollowerAvatar.dimensionsWithinBound(_:)` is pulled out
of `FollowersView.swift` specifically to be tested without the SwiftUI/AppKit code around
it, that logic is pulled out into a standalone `ContactEditValidation` type here and given
a real test.

- [ ] **Step 1: Write `ContactsView.swift`**

```swift
import SwiftUI
import AppKit
import AnglesiteCore

/// Main-pane Contacts surface (Website ▸ Contacts…, #966): the site's private list of known
/// people, with an opt-in "Find in Contacts…" scan. Mirrors `FollowersView`'s wiring shape.
struct ContactsView: View {
    @Bindable var contacts: ContactsModel
    /// Not-yet-added follower actor IRIs to check during a scan. Async because the caller
    /// (`SiteWindowModel`) may need to load Followers first — see
    /// `SiteWindowModel.candidateFollowerURLsForContactsMatching()`.
    let candidateFollowerURLs: () async -> [URL]

    @State private var isPresentingAddSheet = false
    @State private var editingContact: Contact?

    var body: some View {
        Group {
            switch contacts.loadState {
            case .idle:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .corruptFile:
                corruptFileMessage
            case .loaded:
                loadedContent
            }
        }
        .navigationSubtitle("Contacts")
        .task { if contacts.loadState == .idle { await contacts.reload() } }
        .sheet(isPresented: $isPresentingAddSheet) {
            ContactEditSheet(title: "Add Contact", meText: "", displayName: "") { me, displayName in
                await contacts.add(me: me, displayName: displayName)
            }
        }
        .sheet(item: $editingContact) { contact in
            ContactEditSheet(
                title: "Edit Contact", meText: contact.me.absoluteString,
                displayName: contact.displayName
            ) { me, displayName in
                var updated = contact
                updated.me = me
                updated.displayName = displayName
                await contacts.update(updated)
            }
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(contacts.contacts.count) contacts").font(.headline)
                Spacer()
                Button("Find in Contacts…") {
                    Task {
                        let candidates = await candidateFollowerURLs()
                        await contacts.scanForMatches(candidateFollowerURLs: candidates)
                    }
                }
                .disabled(contacts.isScanning)
                Button("Add Contact…") { isPresentingAddSheet = true }
            }
            .padding()

            if let failure = contacts.scanFailure {
                scanFailureBanner(failure)
            }

            if !contacts.suggestions.isEmpty {
                suggestionsSection
            }

            if contacts.contacts.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(contacts.contacts) { contact in
                        contactRow(contact)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Suggestions").font(.subheadline).foregroundStyle(.secondary)
            ForEach(contacts.suggestions, id: \.candidateURL) { suggestion in
                suggestionRow(suggestion)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func suggestionRow(_ suggestion: MatchSuggestion) -> some View {
        HStack {
            // `systemContactName` is Contacts-framework-supplied, and `candidateURL` is a
            // follower/contact-supplied identity — both rendered verbatim via string
            // interpolation into a plain `Text`, never as a localization key.
            switch suggestion.kind {
            case .enrichExisting:
                Text(
                    "Use “\(suggestion.systemContactName)” from Contacts for "
                        + "\(suggestion.candidateURL.host ?? suggestion.candidateURL.absoluteString)?")
            case .promoteToContact:
                Text("“\(suggestion.systemContactName)” matches a follower — add as a contact?")
            }
            Spacer()
            Button("Add") { Task { await contacts.accept(suggestion) } }
            Button("Dismiss") { contacts.dismiss(suggestion) }
        }
    }

    @ViewBuilder
    private func scanFailureBanner(_ failure: ContactsModel.ScanFailure) -> some View {
        HStack {
            switch failure {
            case .permissionDenied:
                Text("Contacts access wasn't granted.")
                Button("Open System Settings") {
                    if let url = URL(
                        string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
            case .other(let reason):
                Text("Couldn't scan Contacts").foregroundStyle(.secondary)
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No contacts yet").font(.title2)
            Text(
                "Add people you know by their website address, or scan Contacts to find people "
                    + "you already follow."
            )
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var corruptFileMessage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Couldn't read your contacts").font(.title2)
            Text(
                "The contacts file may be damaged. Back it up, then remove Config/contacts.json "
                    + "to start fresh."
            )
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func contactRow(_ contact: Contact) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName).font(.headline)
                Text(contact.me.absoluteString).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            linkageBadges(for: contact)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { editingContact = contact }
        .contextMenu {
            Button("Edit…") { editingContact = contact }
            Button("Delete", role: .destructive) { Task { await contacts.remove(contact) } }
        }
    }

    /// Small icon badges showing which identities this contact is linked to (design doc §4).
    /// Purely informational — editing the linkage itself is out of scope (design doc §9).
    @ViewBuilder
    private func linkageBadges(for contact: Contact) -> some View {
        HStack(spacing: 4) {
            if contact.linkedActor != nil {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.secondary)
                    .help("Linked to a Fediverse follower")
            }
            if contact.linkedFeed != nil {
                Image(systemName: "dot.radiowaves.up.forward")
                    .foregroundStyle(.secondary)
                    .help("Linked to a followed feed")
            }
        }
        .font(.caption)
    }
}

/// Add/edit sheet shared by both flows in `ContactsView` — `title` and the initial field values
/// are the only difference between "Add Contact" and "Edit Contact".
private struct ContactEditSheet: View {
    let title: String
    @State var meText: String
    @State var displayName: String
    let onSave: (URL, String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $displayName)
            TextField("Website (e.g. https://example.com)", text: $meText)
            if let validationError {
                Text(validationError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360)
    }

    private func save() {
        switch ContactEditValidation.validate(displayName: displayName, meText: meText) {
        case .failure(let message):
            validationError = message
        case .success(let validated):
            Task {
                await onSave(validated.url, validated.displayName)
                dismiss()
            }
        }
    }
}

/// Pure validation for `ContactEditSheet`'s Save action, pulled out of the view so it can be
/// unit-tested directly — see this task's test strategy note above. Not `private`, for the same
/// testability reason `FollowerAvatar.dimensionsWithinBound(_:)` isn't.
enum ContactEditValidation {
    /// `.success` carries the trimmed name and parsed URL ready to hand to `onSave`; `.failure`
    /// carries the message `ContactEditSheet` shows under the fields.
    static func validate(
        displayName: String, meText: String
    ) -> Result<(url: URL, displayName: String), String> {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return .failure("Enter a name.")
        }
        let trimmedURLText = meText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURLText),
            url.scheme == "http" || url.scheme == "https"
        else {
            return .failure("Enter a valid http(s) website address.")
        }
        return .success((url, trimmedName))
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/AnglesiteAppTests/ContactEditValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteAppCore

@Suite("ContactEditValidation")
struct ContactEditValidationTests {
    @Test("rejects an empty (or whitespace-only) name")
    func rejectsEmptyName() {
        let result = ContactEditValidation.validate(
            displayName: "   ", meText: "https://example.com")
        guard case .failure(let message) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(message == "Enter a name.")
    }

    @Test("rejects a non-http(s) URL")
    func rejectsNonHTTPURL() {
        let result = ContactEditValidation.validate(displayName: "Alice", meText: "ftp://example.com")
        guard case .failure = result else {
            Issue.record("expected failure")
            return
        }
    }

    @Test("rejects unparseable text")
    func rejectsUnparseableText() {
        let result = ContactEditValidation.validate(displayName: "Alice", meText: "not a url")
        guard case .failure = result else {
            Issue.record("expected failure")
            return
        }
    }

    @Test("trims whitespace and accepts a valid https URL")
    func acceptsValidInput() {
        let result = ContactEditValidation.validate(
            displayName: "  Alice  ", meText: "  https://alice.example  ")
        guard case .success(let validated) = result else {
            Issue.record("expected success")
            return
        }
        #expect(validated.displayName == "Alice")
        #expect(validated.url.absoluteString == "https://alice.example")
    }

    @Test("accepts a plain http URL")
    func acceptsHTTP() {
        let result = ContactEditValidation.validate(displayName: "Bob", meText: "http://bob.example")
        guard case .success = result else {
            Issue.record("expected success")
            return
        }
    }
}
```

- [ ] **Step 3: Run tests to verify they fail to compile**

Run: `swift test --package-path . --filter ContactEditValidationTests`
Expected: FAIL — `ContactEditValidation` doesn't exist until Step 1's file is saved.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter ContactEditValidationTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Verify the whole target compiles**

Run: `swift build --package-path . --target AnglesiteAppCore`
Expected: BUILD SUCCEEDED. (`ContactsView` isn't referenced anywhere yet — Task 7 wires
it in — but Swift compiles unreferenced internal types without error.)

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/ContactsView.swift Tests/AnglesiteAppTests/ContactEditValidationTests.swift
git commit -m "feat(#966): add ContactsView"
```

---

### Task 6: Wire `ContactsModel` into `SiteWindowModel`

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindowModel.swift`

**Interfaces:**
- Consumes: `ContactsModel` (Task 4), `MicrosubReaderModel`/`FollowersModel` pattern
  already in this file.
- Produces: `MainPaneMode.contacts` case, `SiteWindowModel.contacts: ContactsModel`
  property, `SiteWindowModel.presentContacts()`, `SiteWindowModel.candidateFollowerURLsForContactsMatching()
  async -> [URL]` — consumed by `SiteWindow.swift` and `WebsiteCommands.swift` in Task 7.

- [ ] **Step 1: Add the `MainPaneMode` case**

In `Sources/AnglesiteApp/SiteWindowModel.swift`, find:

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

Replace with:

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
    case contacts       // Website ▸ Contacts… (#966)
}
```

- [ ] **Step 2: Add the `contacts` model property**

Find:

```swift
    /// Drives the main-pane Moderation view (Website ▸ Moderation…, V-5.1b/V-5.3 #907/#370):
    /// moderator display, and ban/remove actions over this site's members and posts.
    var moderation = ModerationModel()
```

Replace with:

```swift
    /// Drives the main-pane Moderation view (Website ▸ Moderation…, V-5.1b/V-5.3 #907/#370):
    /// moderator display, and ban/remove actions over this site's members and posts.
    var moderation = ModerationModel()
    /// Drives the main-pane Contacts view (Website ▸ Contacts…, #966): the site's private list
    /// of known people, plus an opt-in Contacts.framework matching scan.
    var contacts = ContactsModel()
```

- [ ] **Step 3: Add `presentContacts()` and `candidateFollowerURLsForContactsMatching()`**

Find:

```swift
    func presentModeration() {
        Task {
            guard await leaveCurrentEditor(), await leaveCurrentInspector() else { return }
            activeEditor = nil
            await moderation.reload()
            await clearInspectorThenSwitchPane(to: .moderation)
        }
    }
```

Replace with:

```swift
    func presentModeration() {
        Task {
            guard await leaveCurrentEditor(), await leaveCurrentInspector() else { return }
            activeEditor = nil
            await moderation.reload()
            await clearInspectorThenSwitchPane(to: .moderation)
        }
    }

    /// Switches the main pane to Contacts (Website ▸ Contacts…, #966). Mirrors
    /// `presentModeration()`'s leave-current-surface-first guard.
    func presentContacts() {
        Task {
            guard await leaveCurrentEditor(), await leaveCurrentInspector() else { return }
            activeEditor = nil
            await clearInspectorThenSwitchPane(to: .contacts)
        }
    }

    /// Ensures the Followers collection is loaded before a Contacts.framework matching scan
    /// runs, so a promotion suggestion doesn't come up empty just because the owner never opened
    /// Followers… this session (#966 design doc §5).
    func candidateFollowerURLsForContactsMatching() async -> [URL] {
        if followers.state == .idle {
            await followers.load()
        }
        return followers.rows.map(\.actor)
    }
```

- [ ] **Step 4: Configure `contacts` when a site opens**

Find:

```swift
        reader.configure(site: currentSite)
        followers.configure(site: currentSite)
        communities.configure(site: currentSite)
        await moderation.configure(site: currentSite)
```

Replace with:

```swift
        reader.configure(site: currentSite)
        followers.configure(site: currentSite)
        communities.configure(site: currentSite)
        await moderation.configure(site: currentSite)
        contacts.configure(site: currentSite)
```

- [ ] **Step 5: Verify it compiles**

Run: `swift build --package-path . --target AnglesiteAppCore`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindowModel.swift
git commit -m "feat(#966): wire ContactsModel into SiteWindowModel"
```

---

### Task 7: Wire `ContactsView` into the main pane and the Website menu

**Files:**
- Modify: `Sources/AnglesiteApp/SiteWindow.swift`
- Modify: `Sources/AnglesiteApp/WebsiteCommands.swift`
- Modify: `Sources/AnglesiteApp/Localizable.xcstrings`

**Interfaces:**
- Consumes: `ContactsView` (Task 5), `SiteWindowModel.contacts`/`presentContacts()`/
  `candidateFollowerURLsForContactsMatching()` (Task 6).
- Produces: a reachable "Website ▸ Contacts…" menu item and main-pane surface — the last
  piece needed for the feature to be usable end to end.

- [ ] **Step 1: Add the `.contacts` case to the main-pane switch**

In `Sources/AnglesiteApp/SiteWindow.swift`, find:

```swift
        case .moderation:
            ModerationView(moderation: model.moderation)
        case .preview:
            previewPane(for: site)
```

Replace with:

```swift
        case .moderation:
            ModerationView(moderation: model.moderation)
        case .contacts:
            ContactsView(
                contacts: model.contacts,
                candidateFollowerURLs: { await model.candidateFollowerURLsForContactsMatching() }
            )
        case .preview:
            previewPane(for: site)
```

- [ ] **Step 2: Add the menu item**

In `Sources/AnglesiteApp/WebsiteCommands.swift`, find:

```swift
            Button("Followers…") { model?.presentFollowers() }
                .disabled(model == nil)

            Button("Communities…") { model?.presentCommunities() }
                .disabled(model == nil)
```

Replace with:

```swift
            Button("Followers…") { model?.presentFollowers() }
                .disabled(model == nil)

            Button("Contacts…") { model?.presentContacts() }
                .disabled(model == nil)

            Button("Communities…") { model?.presentCommunities() }
                .disabled(model == nil)
```

- [ ] **Step 3: Add the new user-facing strings to the localization catalog**

In `Sources/AnglesiteApp/Localizable.xcstrings`, find:

```
    "Contacts" : {

    },
```

Replace with (order doesn't affect correctness — `check-localization-catalog.sh` only
checks key presence):

```
    "Contacts" : {

    },
    "Contacts…" : {

    },
    "Contacts access wasn't granted." : {

    },
    "Couldn't read your contacts" : {

    },
    "Couldn't scan Contacts" : {

    },
    "Find in Contacts…" : {

    },
    "Add Contact" : {

    },
    "Add Contact…" : {

    },
    "Edit Contact" : {

    },
    "No contacts yet" : {

    },
    "Open System Settings" : {

    },
    "Suggestions" : {

    },
    "Website (e.g. https://example.com)" : {

    },
```

- [ ] **Step 4: Run the localization catalog check**

Run: `scripts/check-localization-catalog.sh`
Expected: `✓ every scanned localizable literal in Sources/AnglesiteApp has a matching
Sources/AnglesiteApp/Localizable.xcstrings key.`

- [ ] **Step 5: Verify the app builds**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnglesiteApp/SiteWindow.swift Sources/AnglesiteApp/WebsiteCommands.swift Sources/AnglesiteApp/Localizable.xcstrings
git commit -m "feat(#966): add Contacts… to the main pane and Website menu"
```

---

### Task 8: Entitlement, usage description, and Info.plist catalog entry

**Files:**
- Modify: `Resources/Anglesite.entitlements`
- Modify: `Resources/Anglesite-Debug.entitlements`
- Modify: `Resources/Info.plist`
- Modify: `Sources/AnglesiteApp/InfoPlist.xcstrings`

**Interfaces:**
- Consumes: nothing new (declarative config only).
- Produces: the `com.apple.security.personal-information.addressbook` entitlement and
  `NSContactsUsageDescription`, which `CNContactStore.requestAccess` (Task 3) needs to
  successfully prompt instead of crashing the process.

- [ ] **Step 1: Add the entitlement to `Resources/Anglesite.entitlements`**

Find:

```
	<key>com.apple.security.files.bookmarks.app-scope</key>
	<true/>

	<!-- Apple Containerization framework (#69): boot local OCI containers. -->
```

Replace with:

```
	<key>com.apple.security.files.bookmarks.app-scope</key>
	<true/>

	<!-- Contacts.framework read-only matching (#966): suggests linking a system contact to a
	     known identity URL. Unlike the iCloud/webcredentials entitlements below, this needs no
	     special Developer Portal provisioning, so it's safe in both the Release and CI-safe
	     Debug entitlements files. -->
	<key>com.apple.security.personal-information.addressbook</key>
	<true/>

	<!-- Apple Containerization framework (#69): boot local OCI containers. -->
```

- [ ] **Step 2: Add the same entitlement to `Resources/Anglesite-Debug.entitlements`**

Find:

```
	<key>com.apple.security.files.bookmarks.app-scope</key>
	<true/>

	<!-- Apple Containerization framework (#69): boot local OCI containers. -->
```

Replace with:

```
	<key>com.apple.security.files.bookmarks.app-scope</key>
	<true/>

	<!-- Contacts.framework read-only matching (#966): suggests linking a system contact to a
	     known identity URL. Unlike the iCloud/webcredentials entitlements this file
	     deliberately omits, this needs no special Developer Portal provisioning. -->
	<key>com.apple.security.personal-information.addressbook</key>
	<true/>

	<!-- Apple Containerization framework (#69): boot local OCI containers. -->
```

- [ ] **Step 3: Add the usage description to `Resources/Info.plist`**

Find:

```
	<key>NSAppleEventsUsageDescription</key>
	<string>Anglesite needs to coordinate with helper processes (Astro dev server, MCP server) to preview and edit your site.</string>
```

Replace with:

```
	<key>NSAppleEventsUsageDescription</key>
	<string>Anglesite needs to coordinate with helper processes (Astro dev server, MCP server) to preview and edit your site.</string>
	<key>NSContactsUsageDescription</key>
	<string>Anglesite can check your Contacts to suggest names for people you follow, so your contact list uses names you recognize.</string>
```

- [ ] **Step 4: Add the matching catalog entry to `Sources/AnglesiteApp/InfoPlist.xcstrings`**

Find:

```
    "NSAppleEventsUsageDescription" : {
      "comment" : "Privacy - AppleEvents Sending Usage Description",
      "extractionState" : "extracted_with_value",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "new",
            "value" : "Anglesite needs to coordinate with helper processes (Astro dev server, MCP server) to preview and edit your site."
          }
        }
      }
    },
```

Replace with:

```
    "NSAppleEventsUsageDescription" : {
      "comment" : "Privacy - AppleEvents Sending Usage Description",
      "extractionState" : "extracted_with_value",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "new",
            "value" : "Anglesite needs to coordinate with helper processes (Astro dev server, MCP server) to preview and edit your site."
          }
        }
      }
    },
    "NSContactsUsageDescription" : {
      "comment" : "Privacy - Contacts Usage Description",
      "extractionState" : "extracted_with_value",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "new",
            "value" : "Anglesite can check your Contacts to suggest names for people you follow, so your contact list uses names you recognize."
          }
        }
      }
    },
```

- [ ] **Step 5: Verify the app builds with the new entitlements**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED. If this fails with a provisioning-profile error naming the new
entitlement, stop and report it — the design doc's assumption that this entitlement needs
no special provisioning would be wrong, and that's a decision for the issue, not a silent
workaround.

- [ ] **Step 6: Commit**

```bash
git add Resources/Anglesite.entitlements Resources/Anglesite-Debug.entitlements Resources/Info.plist Sources/AnglesiteApp/InfoPlist.xcstrings
git commit -m "feat(#966): add Contacts entitlement and usage description"
```

---

### Task 9: Full verification and manual run-through

**Files:** none (verification only).

**Interfaces:** none — this task consumes everything from Tasks 1–8 and produces
confidence the feature works end to end, including the parts no automated test in this
plan can reach: `CNContactStore.requestAccess`/`enumerateContacts` themselves (TCC-gated
I/O — the pure `matchableContact(from:)` mapping around them is covered by
`SystemContactsProviderTests`) and SwiftUI rendering (`ContactsView`'s layout — the pure
`ContactEditValidation` logic inside it is covered by `ContactEditValidationTests`).

- [ ] **Step 1: Run the full Swift test suite**

Run: `swift test --package-path .`
Expected: all suites pass, including the new `ContactStoreTests`, `ContactsMatcherTests`,
`SystemContactsProviderTests`, `ContactsModelTests`, and `ContactEditValidationTests`.

- [ ] **Step 2: Run the localization catalog check**

Run: `scripts/check-localization-catalog.sh`
Expected: passes (already verified in Task 7, re-checked here in case later edits added
an uncataloged literal).

- [ ] **Step 3: Full Debug app build**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual run-through**

Launch the built `Anglesite.app`, open (or create) a test site, and verify:

1. Website ▸ Contacts… opens a new pane titled "Contacts", showing "No contacts yet".
2. Click "Add Contact…", enter a name and `https://` URL, save — the contact appears in
   the list.
3. Click the new row's context menu ▸ Edit…, change the name, save — the list updates.
4. Click the row's context menu ▸ Delete — the contact disappears, "No contacts yet"
   returns.
5. Quit and relaunch the app, reopen the site, reopen Contacts… — confirm a contact added
   before quitting is still there (`Config/contacts.json` persisted).
6. Add a contact whose `me` URL matches a real entry in the local Contacts app (e.g. add
   your own site's URL as a Website field on your own Contacts card), then click "Find in
   Contacts…". The first click should show the macOS Contacts permission prompt; grant it.
   Confirm a "Use “<name>” from Contacts…" suggestion appears, and that clicking "Add"
   updates the contact's display name.
7. In System Settings ▸ Privacy & Security ▸ Contacts, revoke Anglesite's permission, then
   click "Find in Contacts…" again inside the app — confirm the "Contacts access wasn't
   granted." banner appears with a working "Open System Settings" button, and that the
   rest of the pane (existing contacts, Add Contact…) still works normally.

- [ ] **Step 5: Confirm CONTRIBUTING.md's pre-handoff checklist**

Re-read `CONTRIBUTING.md` ▸ "Commits and pull requests" before opening the PR: subject
lines ≤72 characters (already followed by every commit above), PR body built from
`.github/PULL_REQUEST_TEMPLATE.md`'s actual headings (Summary / Paired PR check / Test
plan), and a `Closes #966` line. This is not an MCP schema change, so the Paired PR check
section should say so explicitly rather than being omitted.
