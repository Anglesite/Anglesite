# ExternalLLMBackend Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `ExternalLLMBackend`, a `URLSession`-based `ConversationalAssistant` that speaks a single OpenAI-compatible chat-completions protocol against a user-configured base URL + API key, and wire it into Settings and the chat backend selector (issue #1482).

**Architecture:** A new, unconditionally-compiled `actor ExternalLLMBackend` in `AnglesiteCore` conforms to the existing `ConversationalAssistant` protocol (the same seam `FoundationModelAssistant` and `ACPAssistant` already implement). It POSTs `{baseURL}/chat/completions` with `stream: true`, parses the `text/event-stream` response incrementally (reusing the `HTTPStreamingRunner`/`bytes(for:)` pattern already proven in `ACPHTTPTransport`), and holds its own actor-private, turn-capped conversation history. Configuration (base URL, model) lives in `AppSettings`/`UserDefaults`; the API key lives in the existing `SecretStore` seam. `AssistantBackendResolver` grows a third resolution branch alongside Foundation Models and ACP agents, wired into `SiteAssistantSessionFactory`'s existing composition chain. A new Settings section (picker row + base URL/model fields + a verifying API-key row) makes it configurable.

**Tech Stack:** Swift 6.4, `URLSession` (Darwin `bytes(for:)` / `FoundationNetworking` via the existing `HTTPStreamingRunner`), Swift Testing, SwiftUI (`AnglesiteApp` target).

## Global Constraints

- Read `CONTRIBUTING.md` in this worktree before making any change — it is the source of truth for workflow, testing, and PR requirements; this plan does not override it.
- Swift Testing (`import Testing`, `@Test`, `#expect`/`#require`), never XCTest, for every new test in `Tests/AnglesiteCoreTests`.
- `generateStructured` and any other `FoundationModels`-touching code must stay behind `#if compiler(>=6.4) && canImport(FoundationModels)` — `ExternalLLMBackend` itself must NOT be gated (it must compile and behave identically on every platform, per the cross-platform design's §8).
- No tool/function calling, no vision input, no per-provider wire-protocol adapters — single OpenAI-compatible chat-completions shape only (design doc §1, §9).
- Never log or persist an API key outside `SecretStore`.
- Conventional commit messages, referencing `#1482` in the subject, ≤72 characters.
- Design reference: [`docs/superpowers/specs/2026-08-16-external-llm-backend-design.md`](../specs/2026-08-16-external-llm-backend-design.md) — consult it for the *why* behind any decision below.

---

### Task 1: `SecretStore` — external LLM API key slot

**Files:**
- Modify: `Sources/AnglesiteCore/Platform/SecretStore.swift`
- Test: `Tests/AnglesiteCoreTests/SecretStoreTests.swift`

**Interfaces:**
- Produces: `SecretAccounts.externalLLMAPIKey: String` (constant), `SecretStore.readExternalLLMAPIKey() throws -> String?`, `SecretStore.writeExternalLLMAPIKey(_ key: String) throws`, `SecretStore.clearExternalLLMAPIKey() throws` — used by Task 6 (resolver) and Task 7 (Settings UI).

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteCoreTests/SecretStoreTests.swift`, inside `struct SecretStoreTests` (next to `gitHubConvenienceUsesSharedAccount`):

```swift
    @Test("External LLM API key convenience methods address the shared SecretAccounts slot")
    func externalLLMAPIKeyConvenienceUsesSharedAccount() throws {
        let store = InMemorySecretStore()
        try store.writeExternalLLMAPIKey("sk-test-123")
        #expect(try store.read(account: SecretAccounts.externalLLMAPIKey) == "sk-test-123")
        #expect(try store.readExternalLLMAPIKey() == "sk-test-123")
        // Distinct from the GitHub slot — writing one must not clobber the other.
        try store.writeGitHubToken("ghp_456")
        #expect(try store.readExternalLLMAPIKey() == "sk-test-123")
        try store.clearExternalLLMAPIKey()
        #expect(try store.readExternalLLMAPIKey() == nil)
        #expect(try store.readGitHubToken() == "ghp_456")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter SecretStoreTests`
Expected: FAIL — `value of type 'InMemorySecretStore' has no member 'writeExternalLLMAPIKey'` (or similar, since `SecretAccounts.externalLLMAPIKey` doesn't exist yet).

- [ ] **Step 3: Add the account constant and convenience methods**

In `Sources/AnglesiteCore/Platform/SecretStore.swift`, add to `SecretAccounts` (after `acpAgentToken(id:)`):

```swift
    /// The API key for the single configured `ExternalLLMBackend` endpoint (#1482). Global, not
    /// per-connection — unlike `acpAgentToken(id:)`, there is only ever one external-LLM config.
    public static let externalLLMAPIKey = "external-llm-api-key"
```

Add to the `public extension SecretStore` block (after the GitHub trio):

```swift
    /// Read the external LLM endpoint's API key under the shared account key.
    func readExternalLLMAPIKey() throws -> String? {
        try read(account: SecretAccounts.externalLLMAPIKey)
    }

    /// Store the external LLM endpoint's API key under the shared account key. Empty string clears.
    func writeExternalLLMAPIKey(_ key: String) throws {
        try write(key, account: SecretAccounts.externalLLMAPIKey)
    }

    /// Clear the external LLM endpoint's API key slot.
    func clearExternalLLMAPIKey() throws {
        try delete(account: SecretAccounts.externalLLMAPIKey)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter SecretStoreTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/Platform/SecretStore.swift Tests/AnglesiteCoreTests/SecretStoreTests.swift
git commit -m "feat(#1482): add SecretStore slot for external LLM API key"
```

---

### Task 2: `AppSettings` — external LLM base URL + model

**Files:**
- Modify: `Sources/AnglesiteCore/AppSettings.swift`
- Test: `Tests/AnglesiteCoreTests/AppSettingsTests.swift`

**Interfaces:**
- Produces: `AppSettings.Key.externalLLMBaseURL`, `AppSettings.Key.externalLLMModel` (String constants); `AppSettings.externalLLMBaseURL: URL?` (get/set), `AppSettings.externalLLMModel: String` (get/set, default `""`) — used by Task 6 (resolver) and Task 7 (Settings UI, via `@AppStorage`).

- [ ] **Step 1: Write the failing test**

Add to `Tests/AnglesiteCoreTests/AppSettingsTests.swift`, inside `final class AppSettingsTests` (anywhere after `init()`/`deinit`):

```swift
    @Test("External LLM base URL round trips and is nil when unset")
    func externalLLMBaseURLRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.externalLLMBaseURL == nil)
        let url = URL(string: "https://api.example.com/v1")!
        settings.externalLLMBaseURL = url
        #expect(settings.externalLLMBaseURL == url)
        settings.externalLLMBaseURL = nil
        #expect(settings.externalLLMBaseURL == nil)
    }

    @Test("External LLM model defaults to empty and round trips")
    func externalLLMModelRoundTrips() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.externalLLMModel == "")
        settings.externalLLMModel = "gpt-4o-mini"
        #expect(settings.externalLLMModel == "gpt-4o-mini")
    }
```

(On Linux/non-Darwin builds, `AppSettings(defaults:)` has no `ubiquityContainerResolver` parameter — match whichever initializer this file's existing `#if canImport(Darwin)` tests already use for a plain `AppSettings(defaults: defaults)` call; several such calls already exist in this file, e.g. around the `sitesRootOverride` tests, so this signature is already proven to compile on both branches.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter AppSettingsTests`
Expected: FAIL — `value of type 'AppSettings' has no member 'externalLLMBaseURL'` / `'externalLLMModel'`.

- [ ] **Step 3: Add the keys and properties**

In `Sources/AnglesiteCore/AppSettings.swift`, add to `enum Key` (after `communitySearchInstance`):

```swift
        /// Backs ``AppSettings/externalLLMBaseURL`` (#1482).
        public static let externalLLMBaseURL = "anglesite.externalLLM.baseURL"
        /// Backs ``AppSettings/externalLLMModel`` (#1482).
        public static let externalLLMModel   = "anglesite.externalLLM.model"
```

Add the properties (after `communitySearchInstance`'s computed property), following the exact `templatePathOverride` shape for the URL:

```swift
    /// Base URL of the user-configured OpenAI-compatible endpoint (#1482) — `nil` until set.
    /// `ExternalLLMBackend` appends `/chat/completions`; this value should NOT include that
    /// suffix. Global, not per-site, matching `activeAssistantBackend`.
    public var externalLLMBaseURL: URL? {
        get {
            guard let raw = defaults.string(forKey: Key.externalLLMBaseURL), !raw.isEmpty else { return nil }
            return URL(string: raw)
        }
        set {
            if let url = newValue {
                defaults.set(url.absoluteString, forKey: Key.externalLLMBaseURL)
            } else {
                defaults.removeObject(forKey: Key.externalLLMBaseURL)
            }
        }
    }

    /// Model name sent as the `model` field of every request to ``externalLLMBaseURL`` (#1482).
    /// Empty string (the default) means "not configured" — `AssistantBackendResolver` requires
    /// this to be non-empty before resolving the backend.
    public var externalLLMModel: String {
        get { defaults.string(forKey: Key.externalLLMModel) ?? "" }
        set { defaults.set(newValue, forKey: Key.externalLLMModel) }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter AppSettingsTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/AppSettings.swift Tests/AnglesiteCoreTests/AppSettingsTests.swift
git commit -m "feat(#1482): add AppSettings keys for external LLM endpoint"
```

---

### Task 3: `ExternalLLMBackend` — configuration, wire format, capabilities

**Files:**
- Create: `Sources/AnglesiteCore/ExternalLLMBackend.swift`
- Create: `Tests/AnglesiteCoreTests/ExternalLLMBackendTests.swift`

**Interfaces:**
- Consumes: `AssistantContext`, `AssistantCapabilities`, `AssistantUsage` (`Sources/AnglesiteCore/ContentAssistant.swift`); `AssistantMessage` (`ContentAssistant.swift`).
- Produces: `ExternalLLMBackend` (plain `actor`, **not yet** declared `: ConversationalAssistant` — that conformance is added in Task 4). `ExternalLLMBackend.Configuration(baseURL:model:apiKey:)`, `ExternalLLMBackend.HTTPError`, `.capabilities: AssistantCapabilities`, `.makeURLRequest(messages:) throws -> URLRequest`, `static .decodeChunk(_:) -> ChatCompletionChunk?`, `static .turnPrompt(for:context:) -> String`, `static .truncatedPageContent(_:) -> String`, internal `ChatMessage(role:content:)`. Task 4 builds directly on all of these.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/ExternalLLMBackendTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ExternalLLMBackend wire format")
struct ExternalLLMBackendWireFormatTests {
    private func makeBackend(apiKey: String? = "sk-test") -> ExternalLLMBackend {
        ExternalLLMBackend(configuration: .init(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: apiKey
        ))
    }

    @Test("capabilities reflect the configured model, no tools/vision/structured output")
    func capabilitiesReflectConfiguration() {
        let backend = makeBackend()
        let caps = backend.capabilities
        #expect(caps.providerName == "Custom (test-model)")
        #expect(caps.supportsStreaming == true)
        #expect(caps.supportsStructuredOutput == false)
        #expect(caps.supportsVision == false)
        #expect(caps.supportsTools == false)
        #expect(caps.maxContextTokens == nil)
    }

    @Test("makeURLRequest appends /chat/completions and trims a trailing slash on baseURL")
    func makeURLRequestAppendsPath() async throws {
        let backend = ExternalLLMBackend(configuration: .init(
            baseURL: URL(string: "https://api.example.com/v1/")!, model: "m", apiKey: nil
        ))
        let request = try await backend.makeURLRequest(messages: [])
        #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
    }

    @Test("makeURLRequest sends a Bearer header only when an API key is configured")
    func makeURLRequestAuthHeader() async throws {
        let withKey = try await makeBackend(apiKey: "sk-test").makeURLRequest(messages: [])
        #expect(withKey.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")

        let withoutKey = try await makeBackend(apiKey: nil).makeURLRequest(messages: [])
        #expect(withoutKey.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("makeURLRequest encodes model, messages, and stream_options.include_usage")
    func makeURLRequestEncodesBody() async throws {
        let backend = makeBackend()
        let request = try await backend.makeURLRequest(messages: [.init(role: "user", content: "hello")])
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["model"] as? String == "test-model")
        #expect(json?["stream"] as? Bool == true)
        let messages = try #require(json?["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "hello"]])
        let streamOptions = try #require(json?["stream_options"] as? [String: Bool])
        #expect(streamOptions["include_usage"] == true)
    }

    @Test("decodeChunk parses a text delta")
    func decodeChunkParsesTextDelta() {
        let chunk = ExternalLLMBackend.decodeChunk(#"{"choices":[{"delta":{"content":"Hi"}}]}"#)
        #expect(chunk?.choices?.first?.delta?.content == "Hi")
    }

    @Test("decodeChunk parses a usage object")
    func decodeChunkParsesUsage() {
        let chunk = ExternalLLMBackend.decodeChunk(#"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#)
        #expect(chunk?.usage?.promptTokens == 10)
        #expect(chunk?.usage?.completionTokens == 5)
    }

    @Test("decodeChunk returns nil for unparsable input")
    func decodeChunkReturnsNilForGarbage() {
        #expect(ExternalLLMBackend.decodeChunk("not json") == nil)
    }

    @Test("turnPrompt folds route and page content ahead of the prompt")
    func turnPromptFoldsContext() {
        let context = AssistantContext(
            siteID: "s1", siteDirectory: URL(fileURLWithPath: "/tmp/s1"),
            currentPageRoute: "/about", currentPageContent: "About us."
        )
        let prompt = ExternalLLMBackend.turnPrompt(for: "Make it shorter", context: context)
        #expect(prompt == "The user is viewing the page at /about.\nCurrent page content:\nAbout us.\nMake it shorter")
    }

    @Test("turnPrompt is just the prompt when context carries no page info")
    func turnPromptWithNoContext() {
        let context = AssistantContext(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/tmp/s1"))
        #expect(ExternalLLMBackend.turnPrompt(for: "hello", context: context) == "hello")
    }

    @Test("truncatedPageContent caps at 2,000 characters with an ellipsis")
    func truncatedPageContentCaps() {
        let long = String(repeating: "a", count: 2_500)
        let truncated = ExternalLLMBackend.truncatedPageContent(long)
        #expect(truncated.count == 2_001) // 2000 chars + "…"
        #expect(truncated.hasSuffix("…"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter ExternalLLMBackendWireFormatTests`
Expected: FAIL to compile — `ExternalLLMBackend` doesn't exist yet.

- [ ] **Step 3: Create the implementation**

Create `Sources/AnglesiteCore/ExternalLLMBackend.swift`:

```swift
import Foundation

/// `URLSession`-based backend speaking a single OpenAI-compatible chat-completions protocol
/// against a user-configured endpoint (#1482) — covers hosted providers and self-hosted local
/// servers (Ollama, llama.cpp, vLLM) with one wire format. Unlike `FoundationModelAssistant`,
/// unconditionally compiled: plain `URLSession` has no platform gate, which is what makes this
/// backend the fastest route to assistant parity off-Darwin (cross-platform design §8).
///
/// See docs/superpowers/specs/2026-08-16-external-llm-backend-design.md for the full design.
/// `ConversationalAssistant` conformance (converse/cancel/resetSession/generate/generateStructured)
/// is added in a later slice of this same file's history — see that type's doc comment once added.
public actor ExternalLLMBackend {
    /// The user-configured endpoint. `baseURL` should NOT include the `/chat/completions`
    /// suffix — a trailing slash, if present, is trimmed and the suffix appended at request time.
    public struct Configuration: Sendable, Equatable {
        public let baseURL: URL
        public let model: String
        public let apiKey: String?

        public init(baseURL: URL, model: String, apiKey: String?) {
            self.baseURL = baseURL
            self.model = model
            self.apiKey = apiKey
        }
    }

    /// Setup-time failures — thrown by `converse` before any event is yielded, per
    /// `ConversationalAssistant`'s documented "outer throws covers setup failure" contract.
    /// Mid-stream failures (connection drop, malformed chunk) surface as `.failed` instead.
    public enum HTTPError: Error, Sendable, Equatable {
        case http(status: Int, body: String?)
        case badResponse
    }

    /// One entry in the actor-held conversation history. A private wire shape, deliberately
    /// distinct from the public `AssistantMessage` so the request format can change without
    /// affecting callers.
    struct ChatMessage: Sendable, Equatable {
        let role: String
        let content: String
    }

    static let systemInstruction = "You are an assistant helping edit and improve a website."
    static let maxPageContentCharacters = 2_000
    /// Oldest non-system messages are dropped once history exceeds this count (design doc §4.1)
    /// — bounds request payload/cost on a paid API. The system instruction (always index 0) is
    /// never counted or dropped.
    static let maxHistoryMessages = 40

    let configuration: Configuration
    let urlSession: URLSession
    var messages: [ChatMessage] = []

    public init(configuration: Configuration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    /// Static, connection-independent capabilities. No tool calling or structured output (those
    /// are FoundationModels/ACP-specific); `providerName` surfaces the configured model so the
    /// chat panel's error messages ("couldn't start Custom (gpt-4o-mini): …") are legible.
    public nonisolated var capabilities: AssistantCapabilities {
        AssistantCapabilities(
            supportsStreaming: true,
            supportsStructuredOutput: false,
            supportsVision: false,
            supportsTools: false,
            maxContextTokens: nil,
            providerName: "Custom (\(configuration.model))"
        )
    }

    // MARK: Wire format

    struct WireMessage: Encodable {
        let role: String
        let content: String
    }

    struct ChatCompletionRequest: Encodable {
        let model: String
        let messages: [WireMessage]
        let stream: Bool
        let streamOptions: StreamOptions

        struct StreamOptions: Encodable {
            let includeUsage: Bool
            enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
        }
        enum CodingKeys: String, CodingKey {
            case model, messages, stream
            case streamOptions = "stream_options"
        }
    }

    struct ChatCompletionChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
        }
        struct Usage: Decodable {
            let promptTokens: Int
            let completionTokens: Int
            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
            }
        }
        let choices: [Choice]?
        let usage: Usage?
    }

    /// Builds the POST request for one turn: `{baseURL}/chat/completions` (trailing slash on
    /// `baseURL` trimmed first), streaming enabled, `Authorization: Bearer` only when a key is
    /// configured (self-hosted servers often need none).
    func makeURLRequest(messages: [ChatMessage]) throws -> URLRequest {
        var base = configuration.baseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else { throw HTTPError.badResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey = configuration.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body = ChatCompletionRequest(
            model: configuration.model,
            messages: messages.map { WireMessage(role: $0.role, content: $0.content) },
            stream: true,
            streamOptions: .init(includeUsage: true)
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Decodes one SSE `data:` payload (already joined across its lines) as a chat-completion
    /// chunk. Returns `nil` for anything that doesn't parse — callers treat that as "ignore this
    /// line" rather than a hard failure, since a comment/keep-alive line is valid SSE traffic.
    static func decodeChunk(_ payload: String) -> ChatCompletionChunk? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ChatCompletionChunk.self, from: data)
    }

    /// Folds `context`'s route/current-page-content into the turn's user message, then appends
    /// the caller's prompt — the same shape as `FoundationModelAssistant.turnPrompt`, but
    /// independently implemented: that type's helpers live inside its
    /// `#if compiler(>=6.4) && canImport(FoundationModels)` gate, unavailable to this ungated type.
    static func turnPrompt(for prompt: String, context: AssistantContext) -> String {
        var lines: [String] = []
        if let route = context.currentPageRoute { lines.append("The user is viewing the page at \(route).") }
        if let content = context.currentPageContent {
            lines.append("Current page content:\n\(truncatedPageContent(content))")
        }
        lines.append(prompt)
        return lines.joined(separator: "\n")
    }

    static func truncatedPageContent(_ content: String) -> String {
        guard content.count > maxPageContentCharacters else { return content }
        return String(content.prefix(maxPageContentCharacters)) + "…"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter ExternalLLMBackendWireFormatTests`
Expected: PASS (11 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ExternalLLMBackend.swift Tests/AnglesiteCoreTests/ExternalLLMBackendTests.swift
git commit -m "feat(#1482): add ExternalLLMBackend wire format and configuration"
```

---

### Task 4: `ExternalLLMBackend` — `ConversationalAssistant` conformance (streaming, history, cancel, generate)

**Files:**
- Modify: `Sources/AnglesiteCore/ExternalLLMBackend.swift`
- Modify: `Tests/AnglesiteCoreTests/ExternalLLMBackendTests.swift`

**Interfaces:**
- Consumes: `ConversationalAssistant`, `AssistantEvent`, `AssistantError` (`ConversationalAssistant.swift`); `TurnRelay` (`TurnRelay.swift`); `HTTPStreamingRunner` (`HTTPStreamingRunner.swift`, non-Darwin only); everything from Task 3.
- Produces: `ExternalLLMBackend: ConversationalAssistant` (full conformance) — used by Task 5 (`AssistantBackendResolver`).

This task turns `ExternalLLMBackend` into a working `ConversationalAssistant`. Because Swift requires every protocol requirement to exist the moment conformance is declared, this task adds the type annotation and all five required methods together, verified by one comprehensive test pass. This is the plan's largest task — treat it as one reviewable deliverable ("does the conversational backend work correctly end to end"), not as several independent ones.

- [ ] **Step 1: Add the SSE stub `URLProtocol` and write the streaming/error/history tests**

First, add the `FoundationModels` import gate to the very top of `Tests/AnglesiteCoreTests/ExternalLLMBackendTests.swift` (needed later in this step for the `generateStructuredThrows` test's `GeneratedPageMeta` reference — matches `FoundationModelAssistantTests.swift`'s own import structure), so the file's imports read:

```swift
import Testing
import Foundation
@testable import AnglesiteCore
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels
#endif
```

Then add, below the imports (above the existing `ExternalLLMBackendWireFormatTests` suite), a dedicated stub modeled on `ACPStubURLProtocol` (`ACPHTTPTransportTests.swift`) — a separate type so its static queue can never race with that suite's:

```swift
/// A dedicated `URLProtocol` stub for `ExternalLLMBackend` tests — modeled on `ACPStubURLProtocol`.
final class ExternalLLMStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
    }
    nonisolated(unsafe) static var queue: [Response] = []
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    static func reset() { queue = []; capturedRequests = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.capturedRequests.append(request)
        let r = Self.queue.isEmpty ? Response(status: 500, headers: [:], body: Data()) : Self.queue.removeFirst()
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !r.body.isEmpty { client?.urlProtocol(self, didLoad: r.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
```

Then append a new suite to the same file:

```swift
@Suite("ExternalLLMBackend conversation", .serialized)
struct ExternalLLMBackendConversationTests {
    private func makeBackend(apiKey: String? = nil) -> ExternalLLMBackend {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExternalLLMStubURLProtocol.self]
        let session = URLSession(configuration: config)
        return ExternalLLMBackend(
            configuration: .init(baseURL: URL(string: "https://api.example.com/v1")!, model: "test-model", apiKey: apiKey),
            urlSession: session
        )
    }

    private func sseBody(_ events: [String]) -> Data {
        (events.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n").data(using: .utf8)!
    }

    private func context() -> AssistantContext {
        AssistantContext(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/tmp/s1"))
    }

    @Test("converse streams text deltas in order and completes")
    func conversesStreamsTextDeltas() async throws {
        ExternalLLMStubURLProtocol.reset()
        let body = sseBody([
            #"{"choices":[{"delta":{"role":"assistant"}}]}"#,
            #"{"choices":[{"delta":{"content":"Hel"}}]}"#,
            #"{"choices":[{"delta":{"content":"lo"}}]}"#
        ])
        ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: body))
        let backend = makeBackend()
        let stream = try await backend.converse(prompt: "hi", context: context())

        var events: [AssistantEvent] = []
        for await event in stream { events.append(event) }

        #expect(events.first == .started(model: "test-model", toolNames: []))
        #expect(events.contains(.textDelta("Hel")))
        #expect(events.contains(.textDelta("lo")))
        #expect(events.last == .turnComplete(nil))
    }

    @Test("usage on the final chunk produces AssistantUsage on turnComplete")
    func usageProducesAssistantUsage() async throws {
        ExternalLLMStubURLProtocol.reset()
        let body = sseBody([
            #"{"choices":[{"delta":{"content":"Hi"}}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#
        ])
        ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: body))
        let backend = makeBackend()
        let stream = try await backend.converse(prompt: "hi", context: context())

        var usage: AssistantUsage?
        for await event in stream {
            if case .turnComplete(let u) = event { usage = u }
        }
        #expect(usage == AssistantUsage(inputTokens: 12, outputTokens: 3))
    }

    @Test("a non-2xx initial response throws before any event is yielded")
    func nonTwoHundredThrows() async throws {
        ExternalLLMStubURLProtocol.reset()
        ExternalLLMStubURLProtocol.queue.append(.init(
            status: 401, headers: [:], body: #"{"error":{"message":"bad key"}}"#.data(using: .utf8)!
        ))
        let backend = makeBackend()
        await #expect(throws: (any Error).self) {
            _ = try await backend.converse(prompt: "hi", context: context())
        }
    }

    @Test("Authorization header carries the configured API key")
    func authorizationHeaderCarriesKey() async throws {
        ExternalLLMStubURLProtocol.reset()
        ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: sseBody([])))
        let backend = makeBackend(apiKey: "sk-test")
        _ = try await backend.converse(prompt: "hi", context: context())
        #expect(ExternalLLMStubURLProtocol.capturedRequests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    }

    @Test("resetSession clears history so the next turn's request carries only the fresh system instruction")
    func resetSessionClearsHistory() async throws {
        ExternalLLMStubURLProtocol.reset()
        ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: sseBody([#"{"choices":[{"delta":{"content":"Hi"}}]}"#])))
        ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: sseBody([#"{"choices":[{"delta":{"content":"Yo"}}]}"#])))
        let backend = makeBackend()

        let first = try await backend.converse(prompt: "hi", context: context())
        for await _ in first {}

        await backend.resetSession()

        let second = try await backend.converse(prompt: "again", context: context())
        for await _ in second {}

        let secondRequestBody = try #require(ExternalLLMStubURLProtocol.capturedRequests.last?.httpBody)
        let json = try JSONSerialization.jsonObject(with: secondRequestBody) as? [String: Any]
        let messages = try #require(json?["messages"] as? [[String: String]])
        // Just the system instruction + the new user turn — the first turn's user/assistant
        // pair is gone.
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[1]["content"]?.hasSuffix("again") == true)
    }

    @Test("history is capped at maxHistoryMessages, oldest turns dropped first, system instruction kept")
    func historyIsCapped() async throws {
        ExternalLLMStubURLProtocol.reset()
        let backend = makeBackend()
        // 25 turns * 2 messages/turn (user+assistant) = 50 > maxHistoryMessages (40), forcing a drop.
        for i in 0..<25 {
            ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: sseBody([#"{"choices":[{"delta":{"content":"ok"}}]}"#])))
            let stream = try await backend.converse(prompt: "turn \(i)", context: context())
            for await _ in stream {}
        }
        let lastRequestBody = try #require(ExternalLLMStubURLProtocol.capturedRequests.last?.httpBody)
        let json = try JSONSerialization.jsonObject(with: lastRequestBody) as? [String: Any]
        let messages = try #require(json?["messages"] as? [[String: String]])
        #expect(messages.count <= 41) // system + maxHistoryMessages
        #expect(messages.first?["role"] == "system")
        #expect(!messages.contains { $0["content"] == "turn 0" })
    }

    @Test("cancel stops delivering further events without corrupting the next turn")
    func cancelStopsDelivery() async throws {
        ExternalLLMStubURLProtocol.reset()
        ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: sseBody([#"{"choices":[{"delta":{"content":"Hi"}}]}"#])))
        ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: sseBody([#"{"choices":[{"delta":{"content":"Yo"}}]}"#])))
        let backend = makeBackend()

        let first = try await backend.converse(prompt: "hi", context: context())
        await backend.cancel()
        var firstEvents: [AssistantEvent] = []
        for await event in first { firstEvents.append(event) }
        #expect(firstEvents.last == .cancelled)

        let second = try await backend.converse(prompt: "again", context: context())
        var sawTextDelta = false
        for await event in second {
            if case .textDelta = event { sawTextDelta = true }
        }
        #expect(sawTextDelta)
    }

    @Test("generate flattens converse's event stream to plain text")
    func generateFlattensToText() async throws {
        ExternalLLMStubURLProtocol.reset()
        let body = sseBody([
            #"{"choices":[{"delta":{"content":"Hel"}}]}"#,
            #"{"choices":[{"delta":{"content":"lo"}}]}"#
        ])
        ExternalLLMStubURLProtocol.queue.append(.init(status: 200, headers: ["Content-Type": "text/event-stream"], body: body))
        let backend = makeBackend()
        let stream = try await backend.generate(prompt: "hi", context: context())
        var text = ""
        for try await chunk in stream { text += chunk }
        #expect(text == "Hello")
    }

#if compiler(>=6.4) && canImport(FoundationModels)
    @Test("generateStructured always throws unsupported")
    func generateStructuredThrows() async throws {
        let backend = makeBackend()
        await #expect(throws: (any Error).self) {
            _ = try await backend.generateStructured(prompt: "hi", context: context(), resultType: GeneratedPageMeta.self)
        }
    }
#endif
}
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `swift test --package-path . --filter ExternalLLMBackendConversationTests`
Expected: FAIL to compile — `ExternalLLMBackend` doesn't conform to `ConversationalAssistant` yet (`converse`/`cancel`/`resetSession`/`generate` don't exist).

- [ ] **Step 3: Add `ConversationalAssistant` conformance**

In `Sources/AnglesiteCore/ExternalLLMBackend.swift`:

1. Add the `FoundationModels` import gate at the top of the file (below `import Foundation`), matching `ACPAssistant.swift`:

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
// Same toolchain/runtime gate as `ContentAssistant.swift` — `Generable` (used only by the
// `generateStructured` conformance below) comes from FoundationModels, which is absent from
// GitHub's macos-15 CI runner at *load* time even when the SDK has the symbol at compile time.
#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels
#endif
```

2. Change the actor declaration line from `public actor ExternalLLMBackend {` to:

```swift
public actor ExternalLLMBackend: ConversationalAssistant {
```

3. Add these members inside the actor body (after the `capabilities` property added in Task 3):

```swift
    var activeRelay: TurnRelay?
    var activeDrainTask: Task<Void, Never>?

    // MARK: ConversationalAssistant

    /// `ContentAssistant`'s plain-text path, implemented by flattening ``converse(prompt:context:)``'s
    /// event stream — same shape as `ACPAssistant.generate`.
    public func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        let events = try await converse(prompt: prompt, context: context)
        return AsyncThrowingStream { continuation in
            Task {
                for await event in events {
                    switch event {
                    case .textDelta(let text): continuation.yield(text)
                    case .failed(let message): continuation.finish(throwing: AssistantError.streamFailed(message)); return
                    case .turnComplete, .backendExited: continuation.finish(); return
                    default: break
                    }
                }
                continuation.finish()
            }
        }
    }

#if compiler(>=6.4) && canImport(FoundationModels)
    /// Always throws: guided generation is defined by FoundationModels' `Generable` machinery,
    /// which a plain HTTP chat-completions endpoint can't participate in.
    public func generateStructured<T: Generable & Sendable>(prompt: String, context: AssistantContext, resultType: T.Type) async throws -> T {
        throw AssistantError.unsupported("External LLM endpoints do not support FoundationModels guided generation")
    }
#endif

    /// Streams one conversational turn. Performs the HTTP request and validates the initial
    /// response *before* returning the stream — a bad response (auth failure, wrong model, DNS
    /// failure) is a setup failure per `ConversationalAssistant`'s documented contract, not an
    /// in-band `.failed` event. Only a failure *after* streaming begins (dropped connection,
    /// malformed chunk) becomes `.failed`.
    public func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        activeRelay?.cancel()
        activeDrainTask?.cancel()

        seedHistoryIfNeeded(context: context)
        messages.append(ChatMessage(role: "user", content: Self.turnPrompt(for: prompt, context: context)))
        trimHistoryIfNeeded()

        let request = try makeURLRequest(messages: messages)

#if canImport(Darwin)
        let (asyncBytes, response) = try await urlSession.bytes(for: request)
#else
        let runner = HTTPStreamingRunner()
        let response = try await runner.start(request, configuration: urlSession.configuration)
#endif
        guard let http = response as? HTTPURLResponse else { throw HTTPError.badResponse }
        guard (200...299).contains(http.statusCode) else {
#if canImport(Darwin)
            let body = await Self.readBounded(asyncBytes)
#else
            let body = await Self.readBounded(runner)
#endif
            throw HTTPError.http(status: http.statusCode, body: body)
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AssistantEvent.self)
        let relay = TurnRelay(continuation)
        activeRelay = relay
        relay.deliver(.started(model: configuration.model, toolNames: []))

#if canImport(Darwin)
        let drainTask = Task { await self.drainSSE(asyncBytes: asyncBytes, relay: relay) }
#else
        let drainTask = Task { await self.drainSSE(runner: runner, relay: relay) }
#endif
        activeDrainTask = drainTask
        continuation.onTermination = { _ in relay.detach() }
        return stream
    }

    /// Ends the current turn for the consumer (`.cancelled`) and stops the underlying network
    /// read — unlike `FoundationModelAssistant.cancel()`, which must leave the on-device stream
    /// running (cancelling it mid-flight traps the process), cancelling a plain HTTP read is safe
    /// and frees the connection promptly.
    public func cancel() async {
        activeRelay?.cancel()
        activeRelay = nil
        activeDrainTask?.cancel()
        activeDrainTask = nil
    }

    public func resetSession() async {
        activeRelay?.cancel()
        activeRelay = nil
        activeDrainTask?.cancel()
        activeDrainTask = nil
        messages = []
    }

    // MARK: History

    /// Seeds the fixed system instruction (and any pre-populated `context.conversationHistory`,
    /// for a caller that supplies it — the primary chat-panel call site never does, per the
    /// design doc §3) the first time this session is used. A no-op on every later turn.
    func seedHistoryIfNeeded(context: AssistantContext) {
        guard messages.isEmpty else { return }
        messages.append(ChatMessage(role: "system", content: Self.systemInstruction))
        for turn in context.conversationHistory {
            messages.append(ChatMessage(role: turn.role.externalLLMWireRole, content: turn.content))
        }
    }

    /// Drops the oldest non-system messages once history exceeds `maxHistoryMessages` — the
    /// system instruction at index 0 is always kept.
    func trimHistoryIfNeeded() {
        let cap = Self.maxHistoryMessages + 1 // +1 for the always-kept system instruction
        guard messages.count > cap else { return }
        messages.removeSubrange(1..<(1 + (messages.count - cap)))
    }

    /// Appends the completed assistant reply to history (so the next turn's request carries it),
    /// trims if needed, and ends the turn with `.turnComplete`.
    private func finishTurn(accumulatedText: String, usage: AssistantUsage?, relay: TurnRelay) {
        messages.append(ChatMessage(role: "assistant", content: accumulatedText))
        trimHistoryIfNeeded()
        relay.complete(.turnComplete(usage))
    }

    // MARK: SSE draining

#if canImport(Darwin)
    private func drainSSE(asyncBytes: URLSession.AsyncBytes, relay: TurnRelay) async {
        var dataLines: [String] = []
        var pendingLineBytes = Data()
        var accumulatedText = ""
        var usage: AssistantUsage?

        func handleLine(_ line: String) -> Bool {
            if line.isEmpty {
                guard !dataLines.isEmpty else { return false }
                let payload = dataLines.joined(separator: "\n")
                dataLines = []
                if payload == "[DONE]" { return true }
                guard let chunk = Self.decodeChunk(payload) else { return false }
                if let delta = chunk.choices?.first?.delta?.content, !delta.isEmpty {
                    accumulatedText += delta
                    relay.deliver(.textDelta(delta))
                }
                if let chunkUsage = chunk.usage {
                    usage = AssistantUsage(inputTokens: chunkUsage.promptTokens, outputTokens: chunkUsage.completionTokens)
                }
                return false
            }
            if line.hasPrefix("data:") {
                let v = line.dropFirst("data:".count)
                dataLines.append(v.hasPrefix(" ") ? String(v.dropFirst()) : String(v))
            }
            return false
        }

        do {
            for try await byte in asyncBytes {
                try Task.checkCancellation()
                pendingLineBytes.append(byte)
                guard byte == 0x0A else { continue }
                var line = String(decoding: pendingLineBytes.dropLast(), as: UTF8.self)
                if line.hasSuffix("\r") { line.removeLast() }
                pendingLineBytes.removeAll(keepingCapacity: true)
                if handleLine(line) {
                    finishTurn(accumulatedText: accumulatedText, usage: usage, relay: relay)
                    return
                }
            }
        } catch {
            relay.complete(.failed(message: "\(error)"))
            return
        }
        if !pendingLineBytes.isEmpty {
            _ = handleLine(String(decoding: pendingLineBytes, as: UTF8.self))
        }
        finishTurn(accumulatedText: accumulatedText, usage: usage, relay: relay)
    }

    private static func readBounded(_ bytes: URLSession.AsyncBytes, limit: Int = 4_096) async -> String? {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            // A partial read is still useful for an error message below.
        }
        return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
    }
#else
    private func drainSSE(runner: HTTPStreamingRunner, relay: TurnRelay) async {
        var dataLines: [String] = []
        var pendingLineBytes = Data()
        var accumulatedText = ""
        var usage: AssistantUsage?

        func handleLine(_ line: String) -> Bool {
            if line.isEmpty {
                guard !dataLines.isEmpty else { return false }
                let payload = dataLines.joined(separator: "\n")
                dataLines = []
                if payload == "[DONE]" { return true }
                guard let chunk = Self.decodeChunk(payload) else { return false }
                if let delta = chunk.choices?.first?.delta?.content, !delta.isEmpty {
                    accumulatedText += delta
                    relay.deliver(.textDelta(delta))
                }
                if let chunkUsage = chunk.usage {
                    usage = AssistantUsage(inputTokens: chunkUsage.promptTokens, outputTokens: chunkUsage.completionTokens)
                }
                return false
            }
            if line.hasPrefix("data:") {
                let v = line.dropFirst("data:".count)
                dataLines.append(v.hasPrefix(" ") ? String(v.dropFirst()) : String(v))
            }
            return false
        }

        do {
            for try await chunk in runner.bodyStream {
                try Task.checkCancellation()
                for byte in chunk {
                    pendingLineBytes.append(byte)
                    guard byte == 0x0A else { continue }
                    var line = String(decoding: pendingLineBytes.dropLast(), as: UTF8.self)
                    if line.hasSuffix("\r") { line.removeLast() }
                    pendingLineBytes.removeAll(keepingCapacity: true)
                    if handleLine(line) {
                        finishTurn(accumulatedText: accumulatedText, usage: usage, relay: relay)
                        return
                    }
                }
            }
        } catch {
            relay.complete(.failed(message: "\(error)"))
            return
        }
        if !pendingLineBytes.isEmpty {
            _ = handleLine(String(decoding: pendingLineBytes, as: UTF8.self))
        }
        finishTurn(accumulatedText: accumulatedText, usage: usage, relay: relay)
    }

    private static func readBounded(_ runner: HTTPStreamingRunner, limit: Int = 4_096) async -> String? {
        var data = Data()
        do {
            for try await chunk in runner.bodyStream {
                data.append(chunk)
                if data.count >= limit { break }
            }
        } catch {
            // A partial read is still useful for an error message below.
        }
        return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
    }
#endif
}

/// Maps the provider-neutral `AssistantMessage.Role` onto the chat-completions wire role string
/// — `ExternalLLMBackend`-only, kept next to the type rather than as a general `AssistantMessage`
/// extension since no other backend needs this mapping (both `FoundationModelAssistant` and
/// `ACPAssistant` maintain their own session state instead of round-tripping `AssistantMessage`).
private extension AssistantMessage.Role {
    var externalLLMWireRole: String {
        switch self {
        case .user: return "user"
        case .assistant: return "assistant"
        case .system: return "system"
        }
    }
}
```

**Note for the implementer:** if the compiler rejects capturing `asyncBytes`/`runner` inside the `Task { }` closure in `converse` (a Sendable-capture diagnostic — this specific "return early, keep streaming in a background Task" shape is new in this codebase; `ACPHTTPTransport` never needs it because it fully awaits its SSE read to completion within one call), capture them via an explicit `[asyncBytes]`/`[runner]` capture list on the closure. `URLSession.AsyncBytes` is documented `Sendable`; if `HTTPStreamingRunner` (non-Darwin) triggers the same diagnostic, mark the specific closure `@Sendable` or move the read into a small local `nonisolated` helper that takes `runner` as a parameter.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter ExternalLLMBackend`
Expected: PASS (all wire-format tests from Task 3 plus all conversation tests from this task — roughly 20 tests total). Fix any compile errors per the implementer note above, or any test-logic mismatch, before moving on — do not proceed with failing tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/ExternalLLMBackend.swift Tests/AnglesiteCoreTests/ExternalLLMBackendTests.swift
git commit -m "feat(#1482): implement ExternalLLMBackend ConversationalAssistant"
```

---

### Task 5: `AssistantBackendResolver` — external LLM resolution branch

**Files:**
- Modify: `Sources/AnglesiteCore/AssistantBackendResolver.swift`
- Modify: `Tests/AnglesiteCoreTests/AssistantBackendResolverTests.swift`

**Interfaces:**
- Consumes: `ExternalLLMBackend`, `ExternalLLMBackend.Configuration` (Task 3/4); `AppSettings.activeAssistantBackend`, `.externalLLMBaseURL`, `.externalLLMModel` (Task 2); `SecretStore.readExternalLLMAPIKey()` (Task 1).
- Produces: `AssistantBackendResolver.resolveActiveExternalLLMAssistant(appSettings:secretStore:urlSession:) -> ExternalLLMBackend?` — used by Task 6.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AnglesiteCoreTests/AssistantBackendResolverTests.swift`, inside `final class AssistantBackendResolverTests`:

```swift
    @Test("resolveActiveExternalLLMAssistant returns nil when backend is not externalLLM")
    func resolveExternalLLMReturnsNilWhenNotSelected() {
        let settings = AppSettings(defaults: defaults)
        settings.activeAssistantBackend = "foundationModels"
        settings.externalLLMBaseURL = URL(string: "https://api.example.com/v1")
        settings.externalLLMModel = "gpt-4o-mini"
        let resolved = AssistantBackendResolver.resolveActiveExternalLLMAssistant(appSettings: settings)
        #expect(resolved == nil)
    }

    @Test("resolveActiveExternalLLMAssistant returns nil when no base URL is configured")
    func resolveExternalLLMReturnsNilWhenNoBaseURL() {
        let settings = AppSettings(defaults: defaults)
        settings.activeAssistantBackend = "externalLLM"
        settings.externalLLMModel = "gpt-4o-mini"
        let resolved = AssistantBackendResolver.resolveActiveExternalLLMAssistant(appSettings: settings)
        #expect(resolved == nil)
    }

    @Test("resolveActiveExternalLLMAssistant returns nil when the model is blank")
    func resolveExternalLLMReturnsNilWhenModelBlank() {
        let settings = AppSettings(defaults: defaults)
        settings.activeAssistantBackend = "externalLLM"
        settings.externalLLMBaseURL = URL(string: "https://api.example.com/v1")
        settings.externalLLMModel = "   "
        let resolved = AssistantBackendResolver.resolveActiveExternalLLMAssistant(appSettings: settings)
        #expect(resolved == nil)
    }

    @Test("resolveActiveExternalLLMAssistant returns a configured assistant when fully set up")
    func resolveExternalLLMReturnsAssistantWhenConfigured() {
        let settings = AppSettings(defaults: defaults)
        settings.activeAssistantBackend = "externalLLM"
        settings.externalLLMBaseURL = URL(string: "https://api.example.com/v1")
        settings.externalLLMModel = "gpt-4o-mini"
        let secretStore = InMemorySecretStore()
        try? secretStore.writeExternalLLMAPIKey("sk-test")
        let resolved = AssistantBackendResolver.resolveActiveExternalLLMAssistant(appSettings: settings, secretStore: secretStore)
        #expect(resolved != nil)
        #expect(resolved?.capabilities.providerName == "Custom (gpt-4o-mini)")
    }
```

`InMemorySecretStore` is the shared test double at `Tests/AnglesiteTestSupport/InMemorySecretStore.swift` — confirm `Tests/AnglesiteCoreTests` already depends on the `AnglesiteTestSupport` target (check `Package.swift`'s `anglesiteCoreTestsDependencies`; other files in this directory, e.g. `CloudflareOAuthCredentialTests.swift`, already use it, so no `Package.swift` change should be needed).

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter AssistantBackendResolverTests`
Expected: FAIL — `type 'AssistantBackendResolver' has no member 'resolveActiveExternalLLMAssistant'`.

- [ ] **Step 3: Add the resolver function**

In `Sources/AnglesiteCore/AssistantBackendResolver.swift`, add after `resolveActiveACPAssistant`:

```swift
    /// Builds an ``ExternalLLMBackend`` for the single configured endpoint, or `nil` when
    /// Foundation Models (or an ACP agent) should handle the session instead. Every failure mode
    /// — backend not selected, no base URL configured, blank model — collapses to `nil`
    /// deliberately, matching ``resolveActiveACPAssistant(siteID:sourceDirectory:containerControlProvider:agentStore:appSettings:secretStore:)``'s
    /// "broken selection degrades to on-device" contract. A `SecretStore` read failure degrades
    /// to an unauthenticated request rather than blocking resolution — some self-hosted servers
    /// need no key at all.
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter AssistantBackendResolverTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/AssistantBackendResolver.swift Tests/AnglesiteCoreTests/AssistantBackendResolverTests.swift
git commit -m "feat(#1482): resolve the active external LLM assistant"
```

---

### Task 6: Wire the resolver into `SiteAssistantSessionFactory`

**Files:**
- Modify: `Sources/AnglesiteApp/SiteAssistantSessionFactory.swift:176`

**Interfaces:**
- Consumes: `AssistantBackendResolver.resolveActiveExternalLLMAssistant()` (Task 5).

No new test is added for this task: `SiteAssistantSessionFactory`'s existing tests (`Tests/AnglesiteAppTests/SiteAssistantSessionFactoryTests.swift`) inject the fallback `dependencies.assistant` closure directly and never configure `AppSettings.shared.activeAssistantBackend`, so they exercise the default `"foundationModels"` path — this change is additive and must not alter their behavior. The full app test suite (Task 8) is the regression check.

- [ ] **Step 1: Make the change**

In `Sources/AnglesiteApp/SiteAssistantSessionFactory.swift`, replace:

```swift
        let resolvedAssistant: any ConversationalAssistant = AssistantBackendResolver.resolveActiveACPAssistant(
            siteID: siteID,
            sourceDirectory: sourceDirectory,
            containerControlProvider: containerControlProvider
        ) ?? dependencies.assistant(
```

with:

```swift
        let resolvedAssistant: any ConversationalAssistant = AssistantBackendResolver.resolveActiveExternalLLMAssistant()
            ?? AssistantBackendResolver.resolveActiveACPAssistant(
                siteID: siteID,
                sourceDirectory: sourceDirectory,
                containerControlProvider: containerControlProvider
            ) ?? dependencies.assistant(
```

(The closing paren structure of the existing `dependencies.assistant(...)` call and its arguments below are unchanged — only the left-hand side of the `??` chain grows a new first branch.)

- [ ] **Step 2: Run the existing factory tests to confirm no regression**

Run: `swift test --package-path . --filter SiteAssistantSessionFactoryTests`
Expected: PASS (unchanged — `AppSettings.shared.activeAssistantBackend` defaults to `"foundationModels"` in the test environment, so the new branch returns `nil` and falls through exactly as before).

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/SiteAssistantSessionFactory.swift
git commit -m "feat(#1482): select the external LLM backend when configured"
```

---

### Task 7: Settings UI — endpoint configuration and picker entry

**Files:**
- Modify: `Sources/AnglesiteApp/SettingsView.swift`

**Interfaces:**
- Consumes: `AppSettings.Key.externalLLMBaseURL`, `.externalLLMModel` (Task 2); `SecretStore.readExternalLLMAPIKey/writeExternalLLMAPIKey/clearExternalLLMAPIKey` via `KeychainStore()` (Task 1); the existing `KeychainTokenRow` component (`SettingsView.swift:580+`).

No dedicated test target exercises `AgentsSettingsView` today (confirmed: no test file references it) — this task is verified by the app build (Task 8), matching the existing testing balance for this file's credential rows (covered indirectly via `SecretStore`/`AppSettings` tests, not view tests).

- [ ] **Step 1: Add the picker row**

In `Sources/AnglesiteApp/SettingsView.swift`, inside `AgentsSettingsView.body`'s `Section("Active Model")`, change:

```swift
            Section("Active Model") {
                Picker("Model", selection: $activeAssistantBackend) {
                    Text("Apple Intelligence (On-Device)").tag("foundationModels")
                    ForEach(agents) { agent in
                        Text(agent.name).tag("acp:\(agent.id.uuidString)")
                    }
                }
                .labelsHidden()
            }
```

to:

```swift
            Section("Active Model") {
                Picker("Model", selection: $activeAssistantBackend) {
                    Text("Apple Intelligence (On-Device)").tag("foundationModels")
                    Text("Custom Endpoint").tag("externalLLM")
                    ForEach(agents) { agent in
                        Text(agent.name).tag("acp:\(agent.id.uuidString)")
                    }
                }
                .labelsHidden()
            }
```

- [ ] **Step 2: Add the External LLM Endpoint section and its verify closure**

In the same `AgentsSettingsView` struct, add new `@State`/`@AppStorage` properties (next to `activeAssistantBackend`):

```swift
    @AppStorage(AppSettings.Key.externalLLMBaseURL) private var externalLLMBaseURLText: String = ""
    @AppStorage(AppSettings.Key.externalLLMModel) private var externalLLMModel: String = ""
```

Add a new `Section`, placed after `Section("Active Model")` and before `Section("ACP Agents")` (always visible, matching the "ACP Agents" section's own always-visible convention):

```swift
            Section("External LLM Endpoint") {
                TextField("Base URL", text: $externalLLMBaseURLText, prompt: Text("https://api.openai.com/v1"))
                TextField("Model", text: $externalLLMModel, prompt: Text("gpt-4o-mini"))
                KeychainTokenRow(
                    title: "API Key",
                    read: { try KeychainStore().readExternalLLMAPIKey() },
                    write: { try KeychainStore().writeExternalLLMAPIKey($0) },
                    clear: { try KeychainStore().clearExternalLLMAPIKey() },
                    verify: { key in await Self.verifyExternalLLMEndpoint(baseURLText: externalLLMBaseURLText, apiKey: key) }
                )
                Text("Works with any OpenAI-compatible chat-completions endpoint — hosted providers or a self-hosted server on this machine or your network (e.g. Ollama, llama.cpp, vLLM). The base URL should not include \"/chat/completions\"; Anglesite appends it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

Add the verify helper as a `static` method on `AgentsSettingsView` (so it needs no `self` capture across the `async` boundary, matching the closure's `Self.` call above):

```swift
    /// GETs `{baseURL}/models` — the OpenAI-compatible endpoint every mainstream provider and
    /// self-hosted server (OpenAI, Groq, vLLM, Ollama, LM Studio) implements — to confirm the
    /// endpoint and key work before the owner starts a chat. A 2xx response whose body parses as
    /// `{"data": [...]}` (the OpenAI list shape) reports a model count; a 2xx response in any
    /// other shape still counts as a successful connection.
    private static func verifyExternalLLMEndpoint(baseURLText: String, apiKey: String) async -> KeychainTokenRow.VerifyOutcome {
        let trimmed = baseURLText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, var base = URL(string: trimmed) else {
            return .failure("enter a base URL first")
        }
        if base.absoluteString.hasSuffix("/") { base = URL(string: String(base.absoluteString.dropLast()))! }
        guard let url = URL(string: base.absoluteString + "/models") else {
            return .failure("enter a base URL first")
        }
        var request = URLRequest(url: url)
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure("no HTTP response") }
            guard (200...299).contains(http.statusCode) else { return .failure("HTTP \(http.statusCode)") }
            var detail: String?
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["data"] as? [Any] {
                detail = "\(models.count) model\(models.count == 1 ? "" : "s") available"
            }
            return .success(.init(label: "Connected", detail: detail, avatarURL: nil))
        } catch {
            return .failure(error.localizedDescription)
        }
    }
```

`KeychainTokenRow` and its nested `VerifyOutcome`/`Identity` types are `private struct`s at the bottom of this same file (confirmed shape as of this plan: `enum VerifyOutcome { case success(Identity); case failure(String) }`, `struct Identity { let label: String; let detail: String?; let avatarURL: URL? }`) — the code above matches that shape exactly. `AgentsSettingsView` and `KeychainTokenRow` are both `private` types declared in the same file, so this is an ordinary same-file access, not a visibility change.

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build --package-path .`
Expected: builds cleanly (this exercises `AnglesiteAppCore`, which includes `Sources/AnglesiteApp/SettingsView.swift` — see the `AnglesiteAppCore is a SwiftPM target` note already established in this codebase).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteApp/SettingsView.swift
git commit -m "feat(#1482): add external LLM endpoint Settings UI"
```

---

### Task 8: Full verification and PR prep

**Files:** none (verification only)

- [ ] **Step 1: Re-read `CONTRIBUTING.md`**

Re-read `CONTRIBUTING.md` in this worktree in full (not from memory) and confirm every applicable requirement in "Testing" and "Commits and pull requests" has been followed by Tasks 1–7.

- [ ] **Step 2: Run the full Swift package test suite**

Run: `swift test --package-path .`
Expected: all suites pass, including `AnglesiteCoreTests` (new `ExternalLLMBackendTests`, `SecretStoreTests`, `AppSettingsTests`, `AssistantBackendResolverTests` cases) and `AnglesiteAppTests` (`SiteAssistantSessionFactoryTests`). If this repo's CI/local toolchain distinguishes Xcode 27 vs. an older toolchain (see `CONTRIBUTING.md`'s note on `AnglesiteAppTests`/`AnglesiteIntentsTests` coverage), run it on the Xcode 27 toolchain locally per that note.

- [ ] **Step 3: Build the app target**

Run:
```bash
scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build
```
Expected: builds cleanly. This is the only way to confirm `SettingsView.swift`'s SwiftUI changes render/compile inside the full app target, not just the SwiftPM library target.

- [ ] **Step 4: Manually verify the Settings UI (best effort)**

If a local run of the built app is possible, open Settings → Agents and confirm: the "Custom Endpoint" picker option appears; the "External LLM Endpoint" section shows Base URL/Model fields and an API Key row; entering a real or fake endpoint and clicking Save on the key row triggers the verify request (a fake/unreachable URL should show a failure message, not a crash). If a live app run isn't possible in this environment, state that explicitly rather than claiming this step was done.

- [ ] **Step 5: Check for stray localization catalog drift**

Since this task added new user-visible strings (`"Custom Endpoint"`, `"External LLM Endpoint"`, `"Base URL"`, `"Model"`, `"API Key"`, the caption text, "Connected"/error strings), follow `CONTRIBUTING.md`'s String Catalog merge recipe if an interactive Xcode build isn't part of this workflow — re-read that section of `CONTRIBUTING.md` now (not from memory) and follow it exactly, including its warnings about scoping `BUILD_DIR` to this worktree and never blindly restoring the catalog.

- [ ] **Step 6: Prepare the PR**

Do not open the PR until the user asks — this step is preparation only. When asked, follow `CONTRIBUTING.md` ▸ "Commits and pull requests" exactly: use `.github/PULL_REQUEST_TEMPLATE.md`'s actual headings (**Summary**, **Paired PR check**, **Test plan**), note in **Paired PR check** that this change touches no MCP message schema (app-only, no sidecar PR needed — design doc §1), and include `Closes #1482` per the template's closing-keyword requirement.

---
