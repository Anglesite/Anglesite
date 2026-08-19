import Foundation

/// Fetches a page's structured model from the sidecar's `get_page_model` MCP tool. Same shape
/// as ``ComponentModelClient`` — same injection seam, same error taxonomy — deliberately, since
/// this is the same MCP round-trip pattern applied to a page instead of a component.
public struct PageModelClient: Sendable {
    /// Injection seam matching ``MCPClient/callTool(name:arguments:)``'s shape, so tests can
    /// feed canned tool results without a live MCP connection.
    public typealias ToolCaller = @Sendable (_ name: String, _ arguments: JSONValue) async throws -> MCPClient.ToolCallResult

    private let toolCaller: ToolCaller

    /// Production initializer. Takes a *provider* closure rather than a client because the MCP
    /// connection comes up asynchronously after the site's runtime starts — resolving it per
    /// call means a fetch made before the connection exists fails cleanly with
    /// ``ModelError/notConnected`` instead of pinning a stale (or nil-forever) client at
    /// construction time.
    public init(mcpClient: @escaping @Sendable () async -> MCPClient?) {
        self.toolCaller = { name, args in
            guard let client = await mcpClient() else { throw ModelError.notConnected }
            return try await client.callTool(name: name, arguments: args)
        }
    }

    /// Test seam.
    public init(toolCaller: @escaping ToolCaller) {
        self.toolCaller = toolCaller
    }

    /// Failures from ``fetch(path:)``, kept `Equatable` and reason-coded so callers
    /// can pick per-failure UI via ``friendlyMessage``.
    public enum ModelError: Error, Equatable {
        /// The client provider returned no live MCP connection — the site runtime isn't up yet
        /// (or went away), so no tool call was attempted at all.
        case notConnected
        /// The tool ran but reported an error result. `reason` is the sidecar's machine-readable
        /// code from its error envelope; `detail` is the human-readable message.
        case toolFailed(reason: String, detail: String)
        /// The tool succeeded but its payload didn't decode as ``PageModel`` — an
        /// app/sidecar schema mismatch, which is why ``friendlyMessage`` suggests updating.
        case decodeFailed(String)
    }

    /// Wire shape of `get_page_model`'s error content: `{type, reason, detail}`.
    private struct FailureEnvelope: Decodable {
        let reason: String
        let detail: String
    }

    /// Fetches the structured model for the page at project-relative `path` (e.g.
    /// `src/pages/index.astro`). Joins all text content blocks before decoding, and decodes
    /// the sidecar's failure envelope on error results so callers get a reason-coded
    /// ``ModelError/toolFailed(reason:detail:)`` rather than an opaque string.
    ///
    /// - Throws: ``ModelError``.
    public func fetch(path: String) async throws -> PageModel {
        let result = try await toolCaller("get_page_model", .object(["path": .string(path)]))
        let text = result.content.compactMap(\.text).joined(separator: "\n")
        guard !result.isError else {
            if let data = text.data(using: .utf8),
               let envelope = try? JSONDecoder().decode(FailureEnvelope.self, from: data) {
                throw ModelError.toolFailed(reason: envelope.reason, detail: envelope.detail)
            }
            throw ModelError.toolFailed(reason: "unknown", detail: text)
        }
        guard let data = text.data(using: .utf8) else { throw ModelError.decodeFailed("non-utf8 payload") }
        do {
            return try JSONDecoder().decode(PageModel.self, from: data)
        } catch {
            throw ModelError.decodeFailed(String(describing: error))
        }
    }
}

extension PageModelClient.ModelError {
    /// User-facing summary for model load errors. Reason-specific messages guide the user
    /// on what went wrong and how to fix it.
    public var friendlyMessage: String {
        switch self {
        case .notConnected:
            return "Site is not running yet."
        case .toolFailed(let reason, let detail):
            switch reason {
            case "read-failed": return "Couldn't read this page: \(detail)"
            // `invalid-input` is the sidecar rejecting the *path* we sent it (e.g. "not a
            // project-relative .astro path: /"). With `PageSourcePath` resolving every caller's
            // path this shouldn't reach an owner at all — but it's now HUD text on the
            // click-to-place failure path, so it gets a sentence written for a person, with the
            // raw detail kept alongside for the log rather than led with.
            case "invalid-input": return "Couldn't place the effect here — try a different spot. (\(detail))"
            case "parse-failed": return detail
            default: return "Something went wrong loading this page: \(detail)"
            }
        case .decodeFailed:
            return "Anglesite couldn't understand the page model returned by the sidecar. Try updating the bundled sidecar."
        }
    }
}
