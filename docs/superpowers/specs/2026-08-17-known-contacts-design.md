# Known contacts as a first-class concept — design (#966)

**Status:** approved design, pre-implementation.
**Issue:** [#966](https://github.com/Anglesite/Anglesite/issues/966), owner-approved
in full 2026-08-15. Related: #963 (contacts epic / auth allowlist), #965 (follow
approval landing spot), #876 (iCloud sync — exclusion), #365 (Microsub reader).

## 1. Context and goal

There is no contact list today. The nearest thing is the opposite of one: the
`member` content type (`ContentTypeRegistry.swift:526`) is a **public** staff
directory rendered into `dist/`. The people the app actually tracks are
scattered across purpose-specific stores — `ActorProfileCache` (federation
display enrichment), the Microsub followed-feed list (reading), the
ActivityPub followers collection (inbound) — and none of them is "people I
know."

**Goal:** a per-site, private contact store that is the pivot point for the
secondary product goal (replace Facebook/LinkedIn for known contacts). It
needs to exist before #963 (an authenticated-read allowlist of `me` URLs) and
#965 (a landing spot for an accepted follower) can be built, though this issue
does not wire either of those up — it ships the store and the hooks they'll
call.

Two capabilities, both approved together by the owner:

1. A per-site contact store: `{ me, displayName, addedDate }` plus optional
   linkage to an ActivityPub actor IRI and a Microsub feed, manually
   manageable (add/edit/delete) with zero dependency on system permissions.
2. Contacts.framework-backed matching: an on-demand scan that compares system
   Contacts against known identity URLs in both directions — enriching a
   manually-added contact with a real name, and suggesting an existing
   follower be promoted to a contact — read-only, fully opt-in, and never
   required for the feature to work.

## 2. Data model

```swift
public struct Contact: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var me: URL              // the person's canonical identity URL
    public var displayName: String
    public let addedDate: Date
    public var linkedActor: URL?    // ActivityPub actor IRI, if promoted from a follower
    public var linkedFeed: URL?     // Microsub-followed feed URL, if linked
}
```

`id` is a stable `UUID`, generated at creation. It is not one of the issue's
literal three fields, but SwiftUI list identity needs a key that survives
editing `me` or `displayName` — the same reasoning `FollowerRow` applies to
`actor.absoluteString`, except a contact's `me` is itself editable so it can't
double as the key.

`linkedFeed` is part of the model now but has no way to be populated by the
promotion flow yet — see §6's documented limitation.

## 3. Storage

`ContactStore`, a new type in `AnglesiteCore`, persists to
`<configDirectory>/contacts.json` — app-owned per-site state per the
`.anglesite` package rules (never in git, alongside `chat-history.jsonl` and
`activitypub-follower-profiles.json`).

Shape follows `ActorProfileCache` (a full-file JSON envelope, pretty-printed,
sorted keys, atomic write) rather than `ChatHistoryStore` (append-only JSONL):
contacts are edited and deleted, not just appended, so an envelope that's
rewritten in full on every mutation is the right fit. Internally keyed by
`me.absoluteString` (URL isn't `Hashable`-stable across normalization, same
reasoning `ActorProfileCache` uses for actor IRIs).

```swift
public actor ContactStore {
    public init(configDirectory: URL, fileManager: FileManager = .default)
    public func load() throws -> [Contact]
    public func add(_ contact: Contact) throws
    public func update(_ contact: Contact) throws   // rekeys if `me` changed
    public func remove(id: UUID) throws
    public func knownMeURLs() -> Set<String>          // forward-looking hook for #963
}
```

**Missing vs. corrupt, precisely:** a *missing* file is the normal first-run
state — `load()` returns `[]`, no error. A file that *exists but fails to
decode* throws, so `ContactsModel` can surface "Couldn't read your contacts —
the file may be damaged" instead of silently presenting an empty list. This
deliberately departs from `ActorProfileCache`'s "corrupt cache costs nothing,
discard silently" posture: a cache is disposable and re-fetchable, but a
contact list is owner-curated data — silently showing zero contacts risks the
owner believing the list was lost and re-entering it by hand. `add`/`update`/
`remove` also throw normally (disk-full, permission errors on `Config/`)
since these are direct user actions expecting feedback.

## 4. UI and menu wiring

Follows the `FollowersModel`/`MainPaneMode` pattern used by Followers,
Reader, Communities, and Moderation — a main-pane switch, not a new pattern:

- `MainPaneMode.contacts` case added.
- `ContactsModel` (`@MainActor @Observable`, `AnglesiteApp`): loads/holds
  `[Contact]` from its site's `ContactStore`, exposes add/edit/remove, and
  (per §5) drives the on-demand matching scan and its suggestions.
- `ContactsView`: a list (display name, `me` URL, linkage badges when
  present), an "Add Contact…" row for manual entry (URL + display name),
  context-menu delete, click-to-edit.
- `SiteWindowModel.presentContacts()` — same leave-current-surface-first
  guard as `presentFollowers()`/`presentReader()`.
- `WebsiteCommands`: `Button("Contacts…") { model?.presentContacts() }`,
  placed next to `Followers…`/`Reader…`, per the issue's menu placement note.

Manual add/edit/delete has zero dependency on Contacts.framework or its
permission — the entire UI in this section works before §5 is ever touched.

## 5. Contacts.framework matching

**Platform seam**, mirroring the `FoundationModelAssistant` precedent for
Apple-framework code inside the portable `AnglesiteCore` target:

```swift
public protocol ContactsProviding: Sendable {
    func matchableContacts() async throws -> [MatchableContact]
    // MatchableContact: displayName, urlAddresses: [URL], socialProfileURLs: [URL]
}

#if canImport(Contacts)
public struct SystemContactsProvider: ContactsProviding { /* CNContactStore-backed */ }
#endif
```

The protocol seam exists so `AnglesiteCoreTests` can inject a fake and test
matching logic in CI without a TCC-gated `CNContactStore` — a bare test binary
can't hold the Contacts permission (same class of problem the sandboxed-probe
precedent solves for App Sandbox).

**`ContactsMatcher`** (`AnglesiteCore`, pure logic, no I/O): given
`matchableContacts()` output and a list of candidate identity URLs (existing
contacts' `me`, plus not-yet-added ActivityPub follower actor IRIs), normalizes
and compares URLs (host + path, scheme-insensitive, trailing-slash-insensitive)
against each system contact's URL/social-profile fields. Produces:

```swift
public struct MatchSuggestion: Equatable, Sendable {
    public let candidateURL: URL
    public let systemContactName: String
    public enum Kind: Equatable, Sendable {
        case enrichExisting(Contact)   // fill in a name for a manually-added contact
        case promoteToContact          // a follower matches a system contact — add them
    }
    public let kind: Kind
}
```

Candidate follower URLs come from `SiteWindowModel.followers` (the
`FollowersModel` instance the window already owns and loads for the Followers
pane) — `ContactsModel` reads its already-loaded `rows`, filtered to actors not
already present in the contact store. It does not independently re-fetch the
followers collection; if the Followers pane hasn't been opened yet this
session, `SiteWindowModel` triggers `followers.load()` before handing rows to
the matcher, so promotion suggestions don't silently come up empty just
because the owner went straight to Contacts….

**Trigger:** a "Find in Contacts…" button in `ContactsView` — no background or
periodic scanning. First click requests Contacts permission in-context
(`CNContactStore.requestAccess`), runs one scan, and populates a
**Suggestions** section above the contact list with Accept/Dismiss per
suggestion. Dismissals are session-only (not persisted) — the same choice
`FollowersModel.unreachableActors` makes — so a later manual scan can
resurface a dismissed match, which is acceptable since scans are always
owner-initiated.

## 6. Permissions and entitlements

- `com.apple.security.personal-information.addressbook` added to both
  `Resources/Anglesite.entitlements` and `Resources/Anglesite-Debug.entitlements`
  — like `network.client`, this entitlement needs no special Developer Portal
  provisioning, unlike the Release-only iCloud/webcredentials entries.
- `NSContactsUsageDescription` added to `Info.plist`:
  *"Anglesite can check your Contacts to suggest names for people you follow,
  so your contact list uses names you recognize."*
- Permission is requested only when "Find in Contacts…" is clicked, never at
  launch or site open.
- Denial/restriction: `ContactsModel` surfaces an inline message ("Contacts
  access wasn't granted — enable it in System Settings ▸ Privacy & Security ▸
  Contacts") with a button that opens that pane. Every other part of the
  Contacts pane keeps working.

**Documented limitation:** promoting a *Microsub feed* to a contact has no
candidate source yet — `MicrosubClient` exposes `follow`/`unfollow` actions
but no "list followed feeds" endpoint. `linkedFeed` stays in the `Contact`
model for forward compatibility, settable only via manual edit until that API
exists. Only ActivityPub followers feed the promotion direction in this
implementation.

## 7. Privacy posture

A contact list is among the most sensitive data the app holds:

- `Config/` is already excluded from the site's git repo and from any sync
  today — this needs no new code, only this explicit statement.
- Excluded from any future iCloud sync (#876) unless that becomes its own,
  separately-reasoned decision.
- The feature is entirely usable — add, edit, delete contacts — without ever
  granting Contacts access; Contacts.framework is pure augmentation,
  opt-in per scan, never required.

## 8. Testing

- `Tests/AnglesiteCoreTests/ContactStoreTests.swift` — round-trip CRUD,
  missing-vs-corrupt-file distinction, `me`-edit rekeying, `knownMeURLs()`.
- `Tests/AnglesiteCoreTests/ContactsMatcherTests.swift` — pure matching logic
  against a fake `ContactsProviding` and fixed candidate-URL lists; URL
  normalization edge cases (scheme, trailing slash); both suggestion kinds.
- `Tests/AnglesiteAppTests/ContactsModelTests.swift` — mirrors the existing
  `FollowersModelTests.swift` pattern for testing an `@Observable` app-glue
  model.

## 9. Explicitly out of scope

- Writing discovered profiles back into system Contacts — the issue defers
  this to a separate, later decision.
- Wiring the store into #963 (auth allowlist) or #965 (follow-approval
  landing spot) — this issue ships `knownMeURLs()`/`add()` as the hooks those
  issues will call, not the call sites themselves.
- Microsub feed promotion (§6's documented limitation).
- Background or periodic Contacts re-scanning.
- Any change to sync behavior — `Config/` already isn't synced anywhere.
