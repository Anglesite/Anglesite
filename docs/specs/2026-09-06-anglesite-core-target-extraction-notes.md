# AnglesiteCore target extraction — measured dependency notes

**Status:** draft
**Date:** 2026-09-06
**Issue:** [#1919](https://github.com/Anglesite/Anglesite/issues/1919) (split from [#1820](https://github.com/Anglesite/Anglesite/issues/1820))

## Question

Step 2 of [#1820](https://github.com/Anglesite/Anglesite/issues/1820) proposes extracting
`AnglesiteSocial` and `AnglesiteCloudflare` as SwiftPM targets, on the premise that `Social/`
and `Cloudflare/` are "the two clusters with the fewest inbound edges from the rest of Core."
#1919 asks whether that premise holds, now that step 1 (the subsystem subfolders) has landed —
using a measurement precise enough to replace the grep-level word-count table in #1820's
original writeup, which the issue itself flagged as over-counting common identifiers
(`Worker`, `Resources`, `Value`, `ID`, …).

**This document records measurements and options. It does not choose an architecture** — the
layering decision stays an owner call on #1820.

## Method

A throwaway Python script (not committed — out of this issue's scope per `CONTRIBUTING.md`)
walked every `.swift` file under `Sources/AnglesiteCore`, bucketed each file into one of three
clusters by path (`Social/`, `Cloudflare/`, or "rest of Core" — everything else), and:

1. **Extracted type declarations.** A regex matched lines declaring a `class`, `struct`,
   `enum`, `protocol`, or `typealias` (with visibility/`final`/`indirect` modifiers and
   attributes stripped), recording which cluster(s) declare each name. **Names declared in more
   than one cluster are excluded from the edge counts below** — a name like `Transport`,
   `Result`, `Content`, or `Error` turned out to be independently declared (usually as a
   same-shaped nested type, e.g. a per-client `typealias Transport = @Sendable (URLRequest)
   async throws -> (Data, HTTPURLResponse)`) in multiple clusters, so a raw match can't tell
   which declaration a reference means. 40 of 1,483 distinct names hit this and were dropped;
   the full list is in the script's output, reproduced in the appendix.
2. **Stripped comments and string literals** from every file before searching for references.
   This mattered more than expected — see the `Empty` example below.
3. **Counted cross-cluster references** by searching, for each name declared in exactly one
   cluster, for a word-boundary match of that name in every file of each *other* cluster
   (excluding the declaring file's own cluster). This is still identifier matching, not a real
   symbol table — it can't distinguish a type reference from a generic type parameter that
   happens to share the name (see the `Body` example below) or from a locally-shadowing nested
   type. Every number below was spot-checked against the actual declaration and at least one
   citing file before being included.
4. **Re-ran the whole pass with comments left in** first, to see how much the naive version
   over-counts. It matters a lot: `Empty` (a `Decodable` type nested privately inside
   `Social/MicrosubClient.swift`) appeared to be referenced by 28 rest-of-Core files under
   naive matching — every one of those was `Empty` appearing in an English doc-comment
   ("Empty when there's no conflict…", "Empty array (never throws)…"), not a single real
   reference. Comment-stripping is why the tables below are much smaller than #1820's original
   estimate (`Social`: 76 citing files → 44; `Cloudflare`: 58 → 25) — the original number was a
   real approximation of "how often related words appear near this code," not "how often this
   type is actually used."

Reproduce with: extract declarations as above from `Sources/AnglesiteCore/**/*.swift` grouped
by top-level subdirectory, strip `//` and `/* */` comments plus string-literal contents, then
grep each single-cluster name against every file of each other cluster.

## 1. Measured dependency tables

File counts: `Social/` 78 files, `Cloudflare/` 58 files, rest-of-Core 419 files.

### Social/ ↔ rest of Core

| Direction | Files with ≥1 reference | Distinct type names crossing |
|---|---|---|
| rest-of-Core types referenced **by** `Social/` files | 44 / 78 | 54 |
| `Social/`-declared types referenced **by** rest-of-Core files | 18 / 419 | 31 |

Top rest-of-Core types `Social/` reaches into (by citing-file count): `LogCenter` (9),
`SecretStore` (8), `CappedHTTPTransport` (8), `SiteConfigStore` (8), `Frontmatter` (6),
`DisplayString` (5), `PlatformSecretStore` (5), `SecretAccounts` (4), `JSONValue` (4),
`TypedContentEditor` (4), `DPoPKeyPair`/`DPoPError`/`DPoPNonceChallenge` (3 each),
`ContentTypeDescriptor` (3), `Values` (3).

Top `Social/` types the rest of Core reaches into: `POSSEHTTPTransport` (3),
`AtprotoPutRecordClient` (3), `SocialMediaPlanning` (2), `PostCollectionResolver` (2),
`Session` (2), `POSSECredentialResolver` (2), `POSSESyndicationCommand` (2), `StrongRef` (2),
`BlobRef` (2), `GeneratedEndpoints` (2), plus 21 names referenced from exactly one file each
(`SocialMediaPlan`, `RepurposePostTool`, `SaveSyndicationTool`, `ActivityAssertion`, …).

### Cloudflare/ ↔ rest of Core

| Direction | Files with ≥1 reference | Distinct type names crossing |
|---|---|---|
| rest-of-Core types referenced **by** `Cloudflare/` files | 25 / 58 | 63 |
| `Cloudflare/`-declared types referenced **by** rest-of-Core files | 42 / 419 | 44 |

Top rest-of-Core types `Cloudflare/` reaches into: `SiteConfigFile` (9),
`WebsiteAnalyticsAsset` (7), `DomainConfig` (7), `DomainConfigStore` (6), `LogCenter` (3),
`DomainConfigAudit` (3), `Experiments`/`Experiment` (3 each), `SecretStore` (2),
`PlatformSecretStore` (2), `SiteConfigStore` (2), `SiteSettings` (2).

Top `Cloudflare/` types the rest of Core reaches into: `HTTPCloudflareClient` (7),
`CloudflareWriting` (5), `CloudflareTransport` (5), `WorkerComposition` (5),
`CloudflareReading` (4), `DeployCommand` (4), `PreDeployCheck` (4),
`SocialWorkerProvisionCommand` (4), `WorkerDescriptor` (4), `DeployCoordinator` (4).

### The shared-base overlap

12 rest-of-Core names are depended on by **both** `Social/` and `Cloudflare/`:
`LogCenter`, `SecretStore`, `PlatformSecretStore` (Platform/SecretStore.swift — the secrets
seam), `SiteConfigStore`, `SiteSettings` (Site/SiteConfigStore.swift), `JSONValue`
(AI/MCPClient.swift), `ProcessSupervisor`, `RunResult` (Container/ProcessSupervisor.swift —
the centralized process-spawning seam CLAUDE.md already calls out), `SwiftGit2Bootstrap`
(GitRepo/), `WebsiteAnalyticsAsset`, `WebsiteIconAsset` (Design/), and `Body` — the last is a
false positive (see Method §3: it's a generic parameter name in the citing files, not a
reference to `Container/HTTPArtifactsClient.swift`'s private nested `Body` struct), leaving
**11 real shared dependencies**.

## 2. The Social/ → Cloudflare/ edge

This is the load-bearing finding: **the dependency is bidirectional**, i.e. a real cycle, not
the one-directional relationship #1820's premise implicitly assumed.

**`Social/` depends on `Cloudflare/` — heavily (12 of 78 files, 9 distinct types):**

| Cloudflare/ type | Citing Social/ files |
|---|---|
| `CloudflareTransport`, `HTTPCloudflareClient` | 9 each — the same 9 files: `BlogrollTrustKVClient`, `BlogrollTrustSync`, `ContactsAllowlistKVClient`, `InboxKVClient`, `InboxSubmissionSync`, `MicropubContentSync`, `MicropubPostD1Client`, `ReceivedInteractionSync`, `WebmentionInboxD1Client` |
| `CloudflareError` | 5 |
| `CloudflareAPICredentials` | 4 |
| `CloudflareAccountLookup` | 3 |
| `WorkerComposition`, `DeployStepResult`, `WorkerRouteClaims`, `OwnedClaim` | 1 each |

Every one of the 9 heaviest citing files is a KV/D1 client for a Social feature (blogroll
trust, contacts allowlist, inbox, micropub, received interactions, webmentions) — they use
Cloudflare's shared HTTP transport and credential/error types to talk to Cloudflare Workers KV
and D1 directly. This is the edge #1919's motivating text flagged: commit 952defa2
("Cloudflare: shared transport in Core", phase 1 of #1818) is actively reshaping exactly this
transport layer.

**`Cloudflare/` depends on `Social/` — lightly but really (4 of 58 files, 10 distinct types,
all single-citation):**

| Social/ type(s) | Citing Cloudflare/ file |
|---|---|
| `WellKnownEndpointDescriptor`, `WellKnownInventory` | `DeployCommand.swift` |
| `ActivityPubFollowersClient`, `ActivityPubOutboxLedger` | `DeployCoordinator.swift` |
| `RuntimeOwnedPathClaim`, `WellKnownClaimManifest`, `WellKnownBuildSeamResult`, `WellKnownBuildSeamOutcome` | `DeployExecutor.swift` |
| `ActivityPubKeyProvisioning`, `Secrets` | `SocialWorkerProvisionCommand.swift` |

All four citing files are **deploy orchestration** — the code that runs a site deploy and, as
part of that, provisions/syncs the social-facing well-known endpoints and ActivityPub
plumbing onto the Cloudflare Worker being deployed. That's a materially different shape than
the Social→Cloudflare edge above (which is "Social features use Cloudflare as a storage/
transport backend"): here, deploy orchestration is reaching *down* into both `Social/` and
`Cloudflare/` internals to wire them together.

**Consequence:** `Social/` and `Cloudflare/` cannot be extracted as independent peer targets
as-is — SwiftPM has no dependency cycles between targets. Whichever comes first would need the
other cluster's symbols (or shared abstractions of them) already available.

## 3. Layering order — options

None of these is a recommendation; they're presented so the owner can pick one on #1820.

**Option A — extract a shared base target first, keep Social/Cloudflare coupled after.**
Pull the 11 genuinely shared symbols (§1) — plus their file-level neighbors, since e.g.
`SiteConfigStore` and `SiteSettings` live in the same file — into a new low-level target
(e.g. `AnglesiteCoreShared`, or extend an existing narrowly-scoped one). Candidate files:
`Platform/SecretStore.swift`, `Site/SiteConfigStore.swift`, `Site/SiteConfigFile.swift`,
`Container/ProcessSupervisor.swift`, `Container/CappedHTTPTransport.swift`,
`LogCenter.swift`, `DisplayString.swift`, `GitRepo/SwiftGit2Bootstrap.swift`,
`Design/WebsiteAnalyticsAsset.swift`, `Design/WebsiteIconAsset.swift`, and the `JSONValue`
type currently sitting inside `AI/MCPClient.swift` (which would need to move — it's an odd
home for a generic JSON value type regardless of this issue). `Social/` and `Cloudflare/`
would both depend on this base, cutting their combined pull on the rest of Core from
54+63=117 names to something smaller, but **does not by itself resolve the §2 cycle** — the
deploy-orchestration edge and the KV/D1-transport edge are both *direct* Social↔Cloudflare
references, not mediated through the shared base.

**Option B — extract deploy orchestration as a third target above both.** The 4 files causing
the light Cloudflare→Social edge (`DeployCommand`, `DeployCoordinator`, `DeployExecutor`,
`SocialWorkerProvisionCommand`) are conceptually "wire a deployed site's social features
together" — a natural fit for a target that sits *above* both `AnglesiteSocial` and
`AnglesiteCloudflare` and depends on both, rather than living inside `Cloudflare/`. That
removes the only Cloudflare→Social edge, leaving Social→Cloudflare one-directional — which
*can* extract as two targets in dependency order (`AnglesiteCloudflare` first, then
`AnglesiteSocial` depending on it). This still leaves the heavy 12-file/9-type Social→
Cloudflare transport dependency (§2) as a hard target dependency, not a cycle to solve, so a
deploy-orchestration split converts the problem from "cycle" to "ordering."

**Option C — combine A and B.** Extract the shared base (Option A) and the deploy-orchestration
layer (Option B) together, then `AnglesiteCloudflare` and `AnglesiteSocial` extract as two
targets with a directed edge (`Social → Cloudflare`) on top of the shared base, and
orchestration sits above both. This is the only option of the three that fully separates
`Social/` and `Cloudflare/` into independent, non-cyclic targets; it's also the most work.

**Option D — do not split Social/Cloudflare as peers; treat them as one target.** Given the
heavy direct coupling in §2 (not mediated by shared abstractions — concrete types crossing
directly in both directions), a single `AnglesiteSocialCloudflare` (or similar) target sidesteps
the cycle question entirely at the cost of not shrinking `AnglesiteCore`'s two biggest
subsystems into fully separate compilation units. This is the "cheapest to build, least value"
option and is included for completeness, not as a suggestion.

## 4. Feasibility verdict for #1820 step 2

**Not one PR.** At minimum:

1. A base-layer extraction PR (Option A's file list, or a subset).
2. A deploy-orchestration PR (Option B's 4 files, if pursued) — this one touches both `Social/`
   and `Cloudflare/` call sites and is the PR most likely to conflict with in-flight work, since
   `DeployCommand`/`DeployCoordinator`/`DeployExecutor` are central to the deploy path.
3. The actual `AnglesiteCloudflare` extraction (58 files, 63 outbound + 44 inbound
   cross-references to redirect).
4. The actual `AnglesiteSocial` extraction (78 files, 54 outbound + 31 inbound
   cross-references to redirect), which must land *after* #3 if Option B/C's directed edge is
   chosen.

That's a 4-PR sequence at minimum (more if the base-layer file list splits further), each
needing its own review and each landing in a repo where other PRs are actively touching the
same files (commit 952defa2 already reshaping `CloudflareTransport`, the exact type at the
center of §2's heavy edge). Attempting step 2 as a single PR against the current, uninverted
graph is not advisable — it would be, in effect, a same-PR layering redesign plus two target
extractions plus a rename of every affected import across ~136 source files and however many
call sites in `Sources/AnglesiteApp` and other consumers of `AnglesiteCore`.

## 5. `portableTargets` impact

`Package.swift:537-543` currently lists only `AnglesiteCore` (among AnglesiteCore-adjacent
targets) in the off-Darwin `portableTargets` set that gates what `linux-build-test`
(`.github/workflows/ci.yml:300`, `swift:6.3.3-noble` container) builds and tests:

```swift
let portableTargets: Set<String> = [
    "AnglesiteSiteModel", "AnglesiteSiteModelTests",
    "AnglesiteQuickLookSupport", "AnglesiteQuickLookSupportTests",
    "AnglesiteCore",
    "AnglesiteBridgeCore", "AnglesiteBridgeCoreTests",
    "AnglesiteCorePortableTests",
]
```

Any new target(s) carved out of `AnglesiteCore` — `AnglesiteSocial`, `AnglesiteCloudflare`,
and whatever base/orchestration layer(s) are chosen in §3 — would need their names **added**
to this set for the Linux lane to keep covering that code (omitting a new target doesn't break
the build, it just silently stops testing that code off-Darwin, re-creating the exact gap
`AnglesiteCoreTests`/`AnglesiteTestSupport` already have per the comment at
`Package.swift`'s Linux-shell job section and `.github/workflows/ci.yml:396-430`).

**Good news found while measuring:** both `Social/` and `Cloudflare/` are already
purity-swept at the file level — every Darwin-only import in either directory
(`Contacts`, `FoundationModels`, `Security` in `Social/`; `OSLog`, `SwiftGit2`/`Clibgit2` in
`Cloudflare/`) is already behind a `#if canImport(Darwin)` or `#if canImport(<Framework>)`
gate, consistent with the cross-platform port's per-file seam pattern (#566/#567). So a new
`AnglesiteSocial`/`AnglesiteCloudflare` target would **not** need new portability work to
compile off-Darwin — it needs (a) its name added to `portableTargets`, and (b) the same
conditional `SwiftGit2` product dependency `AnglesiteCore` already declares
(`Package.swift:60-63`, `#if canImport(Darwin)`), since `Cloudflare/BundleArtifact.swift` and
`Social/InboxSubmissionCommitter.swift` both import `SwiftGit2` under Darwin-only file guards.

CI lanes that would need the new target name(s) added: `linux-build-test`
(`.github/workflows/ci.yml:300`, required) and, for full local coverage,
`scripts/swift-test.sh` needs no change (it wraps `swift test`, which picks up new targets
automatically). The other four macOS jobs a Swift PR runs (CONTRIBUTING.md's "four macOS
jobs" note, `.github/workflows/ci.yml:488,758,870,983`) are `build-test`, `ios-build`, and
`concurrency-tsan` — required, per the `ci` aggregator's `needs:` list at
`.github/workflows/ci.yml:1134-1150` — plus `xcode27-compile`, which is explicitly
**non-required** (its own job name says "Xcode 27 preview, non-required," and it's excluded
from that `needs:` list). All four build the whole package graph already regardless of
required-ness, so none of them need target-name edits, just the new targets to actually
compile.

## Appendix: names excluded as declared in more than one cluster

`Arguments`, `CFAccount`, `CFEnvelope`, `Category`, `CodingKeys`, `CommandResolver`,
`CommandRunner`, `Content`, `DNSRecord`, `Entry`, `Envelope`, `Error`, `Finding`, `Group`,
`HSTS`, `InFlight`, `Item`, `Key`, `Kind`, `LaunchPlan`, `Lease`, `Match`, `Mode`, `Outcome`,
`Plan`, `Post`, `Provider`, `QueryBody`, `QueryResult`, `RenameError`, `Resolution`, `Result`,
`Row`, `Settings`, `StatusResponse`, `Step`, `Subscription`, `Transport`, `ValidationError`,
`VersionProbe`.

`Transport` is worth calling out explicitly since #1919's motivating text named it as a symbol
`Social/` "reaches into": it is **not** a shared type. `Social/ActivityPubFollowers.swift`,
`Cloudflare/GreenHostChecker.swift`, and rest-of-Core's `ATProtoOAuthClient.swift` (among
others) each declare their own private nested `typealias Transport = @Sendable (URLRequest)
async throws -> (Data, HTTPURLResponse)` — the same injectable-HTTP-seam shape, copy-pasted
per type, not one type referenced from three places. The real cross-cluster transport
dependency is `CloudflareTransport` / `HTTPCloudflareClient` (§2), which are genuinely
declared once in `Cloudflare/` and consumed elsewhere.
