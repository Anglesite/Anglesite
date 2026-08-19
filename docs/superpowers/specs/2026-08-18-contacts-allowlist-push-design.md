# Push contact allowlist (me URLs) to Worker store — design (#1567)

**Status:** approved design, pre-implementation.
**Issue:** [#1567](https://github.com/Anglesite/Anglesite/issues/1567), slice 3
of epic #963. Related: #966 (`ContactStore`, shipped — supplies
`knownMeURLs()`), decision record
`docs/superpowers/specs/2026-08-18-audience-limited-posting-decisions.md` §2.3.

## 1. Context and goal

The Worker's future authenticated-read gate (epic #963 slice 4, a separate
issue) needs to check an IndieAuth-authenticated `me` against the site's
contact set. That set lives only on the owner's Mac, in
`Config/contacts.json` via `ContactStore` (#966). `ContactStore.knownMeURLs()`
already exists for exactly this purpose but is unused today.

**Goal:** push the normalized me-URL set to the Worker's KV store whenever a
contact is added or removed, with an unconditional re-push at deploy time as
the consistency backstop (per the epic decision: "revocation takes effect on
the next push"). This issue ships the data path only — the Worker-side read
gate that consumes it is slice 4, out of scope here.

## 2. Storage: `SOCIAL_KV`, single key, bare array

The Worker's per-site `SOCIAL_KV` namespace is already provisioned (used
today for consent rate-limiting in `worker.ts`) — no new KV namespace, D1
table, or migration is needed. One fixed key:

```
contacts:allowlist
```

holding a bare JSON array of `ContactStore.knownMeURLs()`'s output verbatim
— `normalizedIdentityKey(for:)`'s scheme-less `host+path` strings
(`Contact.swift:41`), not full URLs, e.g.:

```json
["alice.example", "bob.example/blog"]
```

No wrapper object, no metadata (`updatedAt`, counts, etc.), no display names
or `linkedActor`/`linkedFeed` data — only the URLs, matching the epic's
minimal-footprint privacy framing (§2.3 of the decision record: salted
hashing was considered and rejected as pointless, since me-URLs are already
public).

## 3. Push mechanism: whole-set replace, no diffing

Both triggers below perform the *identical* operation: read
`ContactStore.knownMeURLs()`, PUT the resulting array to `contacts:allowlist`.
There is no GET-then-compare and no incremental per-URL add/remove call to
KV — the local `Config/contacts.json` is always authoritative, so an
unconditional whole-set PUT is simultaneously "push on change" and
"reconcile."

### New types (`AnglesiteCore`)

- **`ContactsAllowlistKVClient`** — a small HTTP client for the Cloudflare KV
  API, following the same injectable-transport DI pattern as
  `InboxKVClient`/`HTTPCloudflareClient` (no Keychain coupling; the bearer
  token and account/namespace identifiers are passed in at init, sourced the
  same way other KV/D1 clients already get them). One method:

  ```swift
  public struct ContactsAllowlistKVClient: Sendable {
      public func putAllowlist(_ meURLs: Set<String>) async throws
  }
  ```

  Internally: a single `PUT
  /accounts/{account_id}/storage/kv/namespaces/{namespace_id}/values/contacts:allowlist`
  call with the sorted array (sorted for deterministic request bodies /
  easier debugging) as the JSON body.

- **`ContactsAllowlistPusher`** — orchestrator wiring `ContactStore` to the
  KV client:

  ```swift
  public struct ContactsAllowlistPusher: Sendable {
      public func push(store: ContactStore, client: ContactsAllowlistKVClient) async throws
  }
  ```

  `push` calls `store.knownMeURLs()` then `client.putAllowlist(_:)`. No
  caching, no batching — this is called at most a few times per session.

### Call sites

1. **`ContactsModel.add`/`update`/`remove`** (`AnglesiteApp`) — after the
   local `ContactStore` mutation succeeds, fire off the push as a
   best-effort background task. The UI action completes on the local write
   alone; the push never blocks or gates it.
2. **Deploy flow** — alongside where `DomainConfigAudit`/
   `DomainConfigReconciler` already run in the deploy sequence, add an
   unconditional `ContactsAllowlistPusher.push` call after a successful
   `wrangler deploy`, gated on the site's `SOCIAL_KV` namespace ID being
   present in `ProvisionedResources` (i.e., the site has been provisioned at
   least once).

## 4. Error handling

Per the epic's "app applies backend machinery it's confident about without
asking" posture, and because there's no ambiguity here (local state is
always correct), failures are never surfaced as a decision for the owner:

- A push failure during a contact add/remove is logged to the debug pane
  (subprocess/network logging is sacred — never silently swallowed) and
  otherwise invisible. The contact mutation itself already succeeded
  locally.
- If the site has never been deployed/provisioned (no `SOCIAL_KV` namespace
  ID yet), the push is skipped — there's nothing to push to. The first
  successful deploy provisions the namespace and its own reconcile push
  catches the site up.
- A reconcile push failure during deploy is logged but does not fail the
  deploy — the site's actual content deploy is the primary concern; the
  allowlist will retry on the next deploy or next contact mutation.

## 5. Testing

Swift Testing, mirroring `InboxKVClient`'s existing test shape (mock
transport injected at init):

- `ContactsAllowlistKVClientTests` — verifies the PUT request URL, method,
  auth header, and JSON body shape (sorted bare array) for a given me-URL
  set.
- `ContactsAllowlistPusherTests` — verifies `push` reads
  `knownMeURLs()` from a `ContactStore` fixture and forwards exactly that
  set to the client.
- `ContactsModel` tests — verify a push is attempted after each successful
  add/update/remove, and that a failing push does not propagate as a UI-
  visible error or block the mutation.

## 6. Explicitly out of scope

- The Worker (`worker.ts`) reading or checking `contacts:allowlist` at
  all — that's epic #963 slice 4 (the IndieAuth read gate), a separate
  issue.
- Any new KV namespace, D1 table, or provisioning-script changes —
  `SOCIAL_KV` already exists and is provisioned for every site.
- A user-facing retry affordance or drift-confirmation UI (unlike
  `DomainConfigDriftSheetView`) — the correct state here is never ambiguous,
  so no owner decision is needed.
