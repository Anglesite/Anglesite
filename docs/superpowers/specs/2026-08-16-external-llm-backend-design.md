# ExternalLLMBackend — single OpenAI-compatible endpoint config

**Date:** 2026-08-16
**Status:** Design (no implementation yet)
**Issue:** [#1482](https://github.com/Anglesite/Anglesite/issues/1482), split from [#570](https://github.com/Anglesite/Anglesite/issues/570)
**Related:** [`2026-07-08-cross-platform-swift-port-design.md`](2026-07-08-cross-platform-swift-port-design.md) §8, §12;
[`2026-07-14-acp-agent-settings-design.md`](2026-07-14-acp-agent-settings-design.md)

---

## 1. Scope

Implement `ExternalLLMBackend`: a `URLSession`-based `ConversationalAssistant` conformer that
speaks a single, OpenAI-compatible chat-completions HTTP protocol against a user-configured
base URL + API key (owner decision 2026-08-15, resolving the cross-platform design's §12 open
question — one config, not per-provider adapters). This covers hosted providers (OpenAI, Groq,
Together, etc.) and self-hosted local servers (Ollama, llama.cpp, vLLM) with one code path,
since "external to the app" doesn't mean "off the machine."

This is a third, additive `ConversationalAssistant` conformer alongside `FoundationModelAssistant`
(on-device) and `ACPAssistant` (external agentic CLI/remote agents via Agent Client Protocol —
see the related spec's §1 for why those are distinct). It is deliberately **non-tool-calling**
and **HTTP-only** — no platform bindings — which is what makes it buildable ahead of the
Linux/Windows MVPs per the cross-platform design's phasing (§10).

**Out of scope:** the Phi Silica `AssistantBackend` (stays in #570, blocked on the Microsoft LAF
token), tool/function calling, vision input, per-provider wire-protocol adapters (e.g. native
Anthropic Messages API), and any change to `ContentAssistantFactory` (the separate on-device-tier
seam used by one-shot feature helpers like alt-text generation — untouched by this slice).

## 2. Decisions (settled during brainstorming)

| Decision | Choice |
|---|---|
| Wire protocol | Single OpenAI-compatible chat-completions endpoint (resolves cross-platform design §12) |
| Endpoint URL shape | User configures a **base URL** (e.g. `https://api.openai.com/v1`); the app appends `/chat/completions` — matches the OpenAI SDK / litellm / Ollama convention |
| API key verification | Settings includes a **verify** step: `GET {baseURL}/models` on Save, surfaced like the existing GitHub/Cloudflare token rows |
| Conversation history | Actor-held, capped at a fixed message count (oldest dropped first, system instruction always kept) — bounds cost/payload on paid APIs |
| Model field | **Required** alongside base URL for the backend to resolve; missing either falls back silently to on-device Foundation Models (same contract as a removed ACP agent) |
| Auth | `Authorization: Bearer <key>` when a key is configured; omitted otherwise (self-hosted servers often need none) |
| Tool calling | Not supported (`capabilities.supportsTools == false`) — matches the cross-platform design's characterization of this backend as the simplest of the three |
| Structured (guided) generation | Not supported — `FoundationModels.Generable` is on-device-only; always throws `AssistantError.unsupported` under the existing toolchain gate |

## 3. Baseline this builds on

- **`ConversationalAssistant` protocol** (`Sources/AnglesiteCore/ConversationalAssistant.swift`,
  refining `ContentAssistant` in `ContentAssistant.swift`): `converse(prompt:context:) async throws
  -> AsyncStream<AssistantEvent>`, `cancel()`, `resetSession()`, plus `generate(prompt:context:)`
  and `capabilities` from the base protocol. `AssistantEvent` is the provider-neutral event enum
  (`.started`, `.textDelta`, `.turnComplete(AssistantUsage?)`, `.failed`, `.cancelled`, …).
- **`ACPAssistant`** (`Sources/AnglesiteCore/ACPAssistant.swift`) is the closest existing shape to
  copy: a plain `actor` (not FoundationModels-gated), lazy connection on first turn, `generate`
  derived from `converse` by flattening the event stream, `generateStructured` always throwing
  `.unsupported` under the toolchain gate, `nonisolated var capabilities` computed from init-time
  state.
- **`ACPHTTPTransport`** (`Sources/AnglesiteCore/ACPHTTPTransport.swift`) is the existing
  incremental-SSE-over-`URLSession` pattern: `bytes(for:)` on Darwin,
  `HTTPStreamingRunner` (`Sources/AnglesiteCore/HTTPStreamingRunner.swift`) off-Darwin via
  `FoundationNetworking`, byte-by-byte line accumulation with a `maxLineBytes` guard, cooperative
  `Task.checkCancellation()` checks.
- **`TurnRelay`** (`Sources/AnglesiteCore/TurnRelay.swift`) is the reusable, thread-safe,
  once-only-terminal event relay `FoundationModelAssistant` uses so `cancel()` can stop delivery
  without tearing down an in-flight network call.
- **`FoundationModelAssistant.instructions(for:includePageContext:)` /
  `turnPrompt(for:context:)`** (`Sources/AnglesiteCore/FoundationModelAssistant.swift`) is the
  existing pattern for folding `AssistantContext` (route, current page content) into a minimal
  system instruction plus per-turn prompt text.
- **`SecretStore`** (`Sources/AnglesiteCore/Platform/SecretStore.swift`): `read`/`write`/`delete`
  by `account: String`; `SecretAccounts` holds well-known key constants; a `public extension
  SecretStore` adds typed convenience methods per credential (e.g. `readGitHubToken()`). Backed by
  `KeychainStore` on Darwin, via `PlatformSecretStore.make()`.
- **`AppSettings`** (`Sources/AnglesiteCore/AppSettings.swift`): `UserDefaults`-backed, `Key`
  enum of string constants, computed properties with get/set. `activeAssistantBackend` is the
  existing selector: `"foundationModels"` (default) or `"acp:<uuid>"`, resolved by
  `AssistantBackendResolver` (`Sources/AnglesiteCore/AssistantBackendResolver.swift`), whose every
  failure mode collapses to `nil` so the caller falls back to Foundation Models.
- **`SiteAssistantSessionFactory`** (`Sources/AnglesiteApp/SiteAssistantSessionFactory.swift:176`)
  is the single composition point: `AssistantBackendResolver.resolveActiveACPAssistant(...) ??
  dependencies.assistant(...)`.
- **`AgentsSettingsView`** (`Sources/AnglesiteApp/SettingsView.swift:73-180`) is the Settings tab
  with the active-backend `Picker` and the ACP agent list/editor. `KeychainTokenRow`
  (`SettingsView.swift:580+`) is the existing generic credential-row component: `title`,
  `read`/`write`/`clear` closures, and an optional `verify: (String) async -> VerifyOutcome`
  closure that shows a "Connected as …" identity or an inline error.
- **Note on `AssistantContext`:** the chat panel's real call site
  (`Sources/AnglesiteApp/ChatModel.swift:359`) constructs `AssistantContext` with only `siteID`,
  `siteDirectory`, and `searchOptions` — `conversationHistory` is never populated by any caller
  today. Every existing backend therefore holds its own multi-turn session state internally
  (`FoundationModelAssistant`'s cached `LanguageModelSession`, `ACPAssistant`'s persistent
  `sessionID`); `ExternalLLMBackend` follows the same pattern rather than relying on
  `context.conversationHistory`.

## 4. `ExternalLLMBackend` (new: `Sources/AnglesiteCore/ExternalLLMBackend.swift`)

```swift
public actor ExternalLLMBackend: ConversationalAssistant {
    public struct Configuration: Sendable, Equatable {
        public let baseURL: URL       // e.g. https://api.openai.com/v1 — "/chat/completions" is appended
        public let model: String      // non-empty, required by the resolver (see §6)
        public let apiKey: String?    // nil/empty omits the Authorization header
    }

    public init(configuration: Configuration, urlSession: URLSession = .shared)

    // ConversationalAssistant
    public func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent>
    public func cancel() async
    public func resetSession() async

    // ContentAssistant
    public func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error>
    #if compiler(>=6.4) && canImport(FoundationModels)
    public func generateStructured<T: Generable & Sendable>(...) async throws -> T  // always throws .unsupported
    #endif
    public nonisolated var capabilities: AssistantCapabilities
}
```

No platform gate on the type itself (unlike `FoundationModelAssistant`) — plain `URLSession`
compiles and behaves identically everywhere, which is the whole point of this backend per the
cross-platform design.

### 4.1 Session/history

The actor holds `private var messages: [ChatMessage]` (an internal `role`/`content` pair type,
not the public `AssistantMessage` — kept private so the wire format can evolve independently),
seeded lazily on first `converse` with one fixed system instruction (mirrors
`FoundationModelAssistant.instructions`, minimal and stable: "You are an assistant helping edit
and improve a website."). Each turn:

1. Builds the turn's user-message text by folding `context.currentPageRoute`/
   `currentPageContent` into `prompt`, the same shape as
   `FoundationModelAssistant.turnPrompt(for:context:)` — but as its own private static helper with
   its own copy of the `maxPageContentCharacters` (2,000) truncation constant, **not** a call into
   `FoundationModelAssistant`. Its helpers live entirely inside that file's
   `#if compiler(>=6.4) && canImport(FoundationModels)` gate, so they're unavailable on any build
   without FoundationModels (Linux/Windows portable builds, CI on the macos-15 runner) — and
   `ExternalLLMBackend` must stay ungated to be portable. The duplicated logic is small (a handful
   of lines) and intentionally not shared to avoid coupling an ungated type to a gated one.
2. If `context.conversationHistory` is non-empty and this is the very first turn (no cached
   messages beyond the seeded system instruction), seeds `messages` from it before appending —
   covers any future/test caller that does pre-populate history, without the primary chat-panel
   path (which never does) needing to change.
3. Appends the user message, POSTs, streams the assistant reply, and on successful completion
   appends the accumulated assistant text as a `.assistant` message.
4. After appending, if `messages.count` (excluding the system instruction) exceeds
   `maxHistoryMessages` (40 — 20 user/assistant turn-pairs), drops the oldest non-system entries
   until back at the cap. The system instruction is always index 0 and is never dropped.

`resetSession()` clears `messages` back to empty (next `converse` reseeds the system instruction
fresh). `cancel()` uses a `TurnRelay` exactly like `FoundationModelAssistant`: cancels the
underlying `URLSessionTask`/read loop and stops *delivering* further events, without leaving the
actor's state inconsistent for a follow-up turn.

### 4.2 Wire protocol

Request: `POST {baseURL}/chat/completions` (a trailing slash on `baseURL` is trimmed before
appending), `Content-Type: application/json`, `Authorization: Bearer <key>` when configured.

```json
{
  "model": "<configured model>",
  "messages": [{"role": "system"|"user"|"assistant", "content": "..."}],
  "stream": true,
  "stream_options": {"include_usage": true}
}
```

`stream_options.include_usage` is an OpenAI extension also honored by recent vLLM/Ollama — sent
opportunistically; a server that ignores unknown fields (the common case) is unaffected, and one
that rejects unknown top-level keys is not a case this backend special-cases (documented
limitation, not a bug to work around — the single-config approach trades per-provider quirks for
uniformity, per the issue's explicit direction).

Response is expected `text/event-stream`. Parsing reuses the byte-by-byte incremental reader
pattern from `ACPHTTPTransport` (`bytes(for:)` / `HTTPStreamingRunner`) but simplified — no
JSON-RPC id-matching:

- Accumulate `data:` lines until a blank line, decode the joined payload as JSON.
- `data: [DONE]` (not JSON) ends the stream normally.
- Each decoded chunk: `choices[0].delta.content`, if present and non-empty, yields
  `.textDelta(...)`. A `usage` object anywhere in the stream (present only on the final chunk per
  the OpenAI convention) is captured and turned into `AssistantUsage(inputTokens:
  prompt_tokens, outputTokens: completion_tokens)` — emitted with the terminal
  `.turnComplete(usage)`; `nil` if the server never sent one.
- `.started(model: configuredModel, toolNames: [])` is emitted before the first byte is read
  (this backend never has tools, so `toolNames` is always empty — `capabilities.supportsTools ==
  false` is the authoritative signal; the event's own array is just structurally consistent).

Error handling:

- A non-2xx **initial** response (checked from the response headers before any body is read, same
  as `ACPHTTPTransport`) throws — covers "setup failure" per `ConversationalAssistant`'s
  documented contract (bad key, bad model, endpoint down). The thrown error is a new
  `ExternalLLMBackend.HTTPError.http(status: Int, body: String?)` (bounded-size body capture for a
  useful message, mirroring how `ChatModel` already renders `error.localizedDescription`).
- A failure **after** streaming starts (connection drop, malformed chunk) yields
  `.failed(message:)` on the stream rather than throwing — matches `AssistantEvent.failed`'s
  documented "in-band error the backend reported" semantics, and lets `ConversationTranscript`
  render it as a chat-visible error row instead of silently ending the turn.
- No retries — matches `ACPHTTPTransport`'s existing behavior for the same class of failure.

### 4.3 Capabilities

```swift
AssistantCapabilities(
    supportsStreaming: true,
    supportsStructuredOutput: false,
    supportsVision: false,
    supportsTools: false,
    maxContextTokens: nil,   // unknowable across arbitrary providers
    providerName: "Custom (\(configuration.model))"
)
```

## 5. `AppSettings` / `SecretStore` additions

`Sources/AnglesiteCore/AppSettings.swift`:

```swift
public enum Key {
    // ...
    public static let externalLLMBaseURL = "anglesite.externalLLM.baseURL"
    public static let externalLLMModel   = "anglesite.externalLLM.model"
}

public var externalLLMBaseURL: URL? {
    get { /* string(forKey:) -> URL(string:), nil if empty/invalid, same shape as templatePathOverride */ }
    set { /* set or removeObject */ }
}

public var externalLLMModel: String {
    get { defaults.string(forKey: Key.externalLLMModel) ?? "" }
    set { defaults.set(newValue, forKey: Key.externalLLMModel) }
}
```

Both plain (non-secret) `UserDefaults` values, consistent with every other non-credential setting
in this file.

`Sources/AnglesiteCore/Platform/SecretStore.swift`:

```swift
public enum SecretAccounts {
    // ...
    /// The API key for the single configured `ExternalLLMBackend` endpoint (#1482). Global, not
    /// per-connection — unlike `acpAgentToken(id:)`, there is only ever one external-LLM config.
    public static let externalLLMAPIKey = "external-llm-api-key"
}

public extension SecretStore {
    func readExternalLLMAPIKey() throws -> String?
    func writeExternalLLMAPIKey(_ key: String) throws
    func clearExternalLLMAPIKey() throws
}
```

## 6. Backend selection

`activeAssistantBackend` grows a third convention value: the literal string `"externalLLM"` (no
UUID suffix — there is only one configured endpoint, unlike the ACP agent registry).

`Sources/AnglesiteCore/AssistantBackendResolver.swift` gains:

```swift
public static func resolveActiveExternalLLMAssistant(
    appSettings: AppSettings = .shared,
    secretStore: any SecretStore = PlatformSecretStore.make(),
    urlSession: URLSession = .shared
) -> ExternalLLMBackend? {
    guard appSettings.activeAssistantBackend == "externalLLM" else { return nil }
    guard let baseURL = appSettings.externalLLMBaseURL else { return nil }
    let model = appSettings.externalLLMModel.trimmingCharacters(in: .whitespaces)
    guard !model.isEmpty else { return nil }
    let apiKey = try? secretStore.readExternalLLMAPIKey()
    return ExternalLLMBackend(
        configuration: .init(baseURL: baseURL, model: model, apiKey: apiKey),
        urlSession: urlSession
    )
}
```

Every failure mode (backend not selected, base URL unset, model blank) collapses to `nil` —
identical fallback contract to `resolveActiveACPAssistant`'s "agent removed" case. A `SecretStore`
read failure degrades to an unauthenticated request (same precedent as `ACPAssistant`'s remote
transport), not a resolution failure — a key that fails to read is still worth trying against a
server that might not require one.

`Sources/AnglesiteApp/SiteAssistantSessionFactory.swift:176` becomes a three-way chain:

```swift
let resolvedAssistant: any ConversationalAssistant = AssistantBackendResolver.resolveActiveExternalLLMAssistant()
    ?? AssistantBackendResolver.resolveActiveACPAssistant(
        siteID: siteID, sourceDirectory: sourceDirectory, containerControlProvider: containerControlProvider
    )
    ?? dependencies.assistant(...)
```

Order is arbitrary between the first two (their guard conditions are mutually exclusive on
`activeAssistantBackend`'s value), external-LLM checked first only because it's the cheaper,
synchronous check.

## 7. Settings UI (`Sources/AnglesiteApp/SettingsView.swift`)

`AgentsSettingsView`'s picker gains a row:

```swift
Text("Custom Endpoint").tag("externalLLM")
```

A new `Section("External LLM Endpoint")`, always visible (like "ACP Agents" is, regardless of
which backend is currently active):

```swift
Section("External LLM Endpoint") {
    TextField("Base URL", text: $baseURLText, prompt: Text("https://api.openai.com/v1"))
    TextField("Model", text: $model, prompt: Text("gpt-4o-mini"))
    KeychainTokenRow(
        title: "API Key",
        read: { try KeychainStore().readExternalLLMAPIKey() },
        write: { try KeychainStore().writeExternalLLMAPIKey($0) },
        clear: { try KeychainStore().clearExternalLLMAPIKey() },
        verify: { key in await verifyEndpoint(baseURLText: baseURLText, key: key) }
    )
}
```

`baseURLText`/`model` are plain `@AppStorage`-style bindings to the new `AppSettings` keys (same
pattern as `activeAssistantBackend`'s `@AppStorage` in the same view). `verifyEndpoint` issues
`GET {baseURL}/models` (with the `Authorization` header if `key` is non-empty) using a short-lived
`URLSession` request, and maps the result to `KeychainTokenRow.VerifyOutcome`:

- 2xx with a JSON body → `.success(Identity(label: "Connected", detail: modelCountDetail, avatarURL: nil))`,
  where `modelCountDetail` is `"<N> models available"` when the body parses as
  `{"data": [...]}` (the OpenAI `/models` list shape) and `nil` otherwise (still a successful
  connection, just without a count — plenty of OpenAI-compatible servers respond to `/models` with
  a differently-shaped but still-2xx body).
- Non-2xx or a network error → `.failure("<status/description>")`.
- An unparsable/missing base URL → `.failure("enter a base URL first")` without making a request.

This mirrors the existing `verify` closures for GitHub/Cloudflare token rows in the same file —
no new component needed, only a new closure passed to the existing generic `KeychainTokenRow`.

## 8. Testing

`Tests/AnglesiteCoreTests/ExternalLLMBackendTests.swift` (Swift Testing, matching every other
test in this target), using a custom `URLProtocol` stub feeding canned SSE bodies — same approach
as `ACPHTTPTransportTests`'s stub:

- Streams accumulate `.textDelta` chunks in order and terminate on `data: [DONE]`.
- `usage` on the final chunk produces the matching `AssistantUsage` on `.turnComplete`; its
  absence produces `.turnComplete(nil)`.
- A non-2xx initial response throws before any event is yielded.
- A mid-stream malformed chunk / connection failure yields `.failed`, not a thrown error.
- `cancel()` stops delivery without corrupting a subsequent turn's history.
- `resetSession()` drops accumulated history (verified indirectly: the next request's `messages`
  body contains only the fresh system instruction + new turn).
- History capping: pushing more than `maxHistoryMessages` turns keeps the system instruction and
  drops the oldest user/assistant pairs (asserted on the outgoing request body across turns).
- `generateStructured` throws `.unsupported` under the toolchain gate (mirrors the existing
  `ACPAssistant` test for the same behavior, if one exists — otherwise a new minimal case).

`Tests/AnglesiteCoreTests/AssistantBackendResolverTests.swift` gains cases for
`resolveActiveExternalLLMAssistant`: not selected → `nil`; selected with no base URL → `nil`;
selected with blank model → `nil`; fully configured → non-`nil` with the expected
`Configuration`.

`Tests/AnglesiteCoreTests/AppSettingsTests.swift` gains round-trip cases for
`externalLLMBaseURL`/`externalLLMModel` (get/set/clear), following the existing pattern for
`templatePathOverride`/`sitesRootOverride`.

No new SwiftUI-view test coverage is added beyond what `SettingsView.swift` already has (none —
confirmed no existing test target exercises `AgentsSettingsView` directly); this matches the
existing testing balance in that file, where credential rows are covered indirectly via
`SecretStore`/`AppSettings` tests, not view tests.

## 9. Non-goals / explicit limitations (for the PR description)

- No per-provider adapters (Anthropic Messages API, etc.) — single OpenAI-compatible shape only,
  per the issue title and the resolved §12 open question.
- No tool/function calling, no vision input.
- No token-based context budgeting (unlike `FoundationModelAssistant`'s character-based proxy) —
  history capping is turn-count-based, not token-aware, since token limits vary per arbitrary
  provider/model with no universal way to query them.
- No custom header support for auth schemes other than `Authorization: Bearer` — a provider
  needing e.g. an `api-key` header isn't served by this slice (would be a per-provider adapter,
  explicitly out of scope).
- `PlatformCapabilities.hasAssistant`/`modelTier` are **not** touched by this slice — they
  currently reflect on-device-only availability; teaching them about an active external-LLM
  selection is left for whenever the cross-platform port's capability-tier work actually lands
  (§8 of the cross-platform design), since it's not needed for this backend to function on macOS
  today.
