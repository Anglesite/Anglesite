import Foundation
import AnglesiteCore
import AnglesiteP2P
import os.log

/// Wraps an `MCPChannelResponder.Handler` (in practice, `LoopbackMCPBridge.handle`) so that after
/// relaying a reply verbatim, any commit-bearing edit reply gets the same guest-to-host
/// persistence hop `LocalContainerSiteRuntime.persistEdit` already performs for the main app —
/// the app-side half of the Anywhere-runtime P1 exit criterion the shipped `LoopbackMCPBridge`
/// deliberately left unwired (design spec §Architecture 5; see `HelperContainerE2ETests`'s
/// doc comment for the shipped gap this closes).
///
/// Reply timing mirrors `MCPApplyEditRouter.apply`'s existing "await persist before acknowledging"
/// ordering, which exists specifically to avoid #718-style data loss (acknowledging an edit
/// before it is durable). On persist failure, the reply that reaches the caller is NOT the
/// original "applied" body — it is synthesized into a JSON-RPC error carrying the same request
/// id, so a phone/client cannot come away believing an edit landed on `Source/` when it didn't.
/// Every other reply (no commit, or a `.isError` tool-level failure) passes through completely
/// unmodified — this decorator only ever *replaces* a reply for the specific case it just caused
/// (a persist failure of its own), never edits the container's own success/failure verdict.
///
/// **Known limitation: only the first commit-bearing edit in a session is guaranteed to
/// persist.** `InProcessEditPersistence.performImport` re-commits the guest's imported edit
/// under the host's own git identity (`InProcessEditPersistence.swift`, around line 78-84),
/// so after a successful persist, host `Source/` HEAD is a *new*, re-signed commit the guest's
/// `/workspace/site` clone is never told about. A second edit in the same session commits in
/// the guest on top of the guest's own (now-superseded) prior commit, so its export's parent no
/// longer matches the host's new HEAD — `InProcessEditPersistence`'s fast-forward-only
/// precondition then refuses it with `"overlay edit conflicts with newer Source changes"`, and
/// this handler synthesizes that into a JSON-RPC error even though the edit is live in the
/// guest. Confirmed empirically: `swift test --filter HelperContainerE2ETests` with a second
/// `apply_edit` appended to `secondProcessPersistsAnApplyEditToHostSource` reproduced exactly
/// this failure. Not yet fixed — doing so needs the helper to run a `syncFromHost`-equivalent
/// resync of the guest's clone after every successful persist, which is a real design change,
/// not a small patch (tracked for follow-up, not fixed in this pass).
public actor HelperEditPersister {
    private static let logger = os.Logger(subsystem: "io.dwk.anglesite.remote", category: "HelperEditPersister")

    public typealias Handler = MCPChannelResponder.Handler

    private let inner: Handler
    private let siteID: String
    private let control: any LocalContainerControl
    private let sourceDirectory: URL
    private let onLog: @Sendable (String, LogCenter.Stream) -> Void
    private let exportAndImport: @Sendable (String, String, any LocalContainerControl, URL, @escaping @Sendable (String, LogCenter.Stream) -> Void) async throws -> Void

    /// - Parameters:
    ///   - inner: The handler to wrap — production always passes `LoopbackMCPBridge.handle`.
    ///   - siteID: The container's identity, passed straight to `exportAndImport`.
    ///   - control: The **same** `LocalContainerControl` instance that booted `siteID` — see
    ///     `ContainerEditExport.exportAndImport`'s doc comment for why this must not be a second,
    ///     freshly constructed instance.
    ///   - sourceDirectory: The host's canonical `Source/` git repository to import into.
    ///   - onLog: Routed to the helper's own log sink (stderr + `os.Logger`, matching
    ///     `RemoteContainerSession.report`/`LoopbackMCPBridge.report`'s existing pattern).
    ///   - exportAndImport: The guest-export + host-import hop. Defaults to
    ///     `ContainerEditExport.exportAndImport`; injectable for tests.
    public init(
        wrapping inner: @escaping Handler,
        siteID: String,
        control: any LocalContainerControl,
        sourceDirectory: URL,
        onLog: @escaping @Sendable (String, LogCenter.Stream) -> Void,
        exportAndImport: @escaping @Sendable (String, String, any LocalContainerControl, URL, @escaping @Sendable (String, LogCenter.Stream) -> Void) async throws -> Void
            = { commit, siteID, control, sourceDirectory, onLog in
                try await ContainerEditExport.exportAndImport(
                    commit: commit, siteID: siteID, control: control, sourceDirectory: sourceDirectory, onLog: onLog)
            }
    ) {
        self.inner = inner
        self.siteID = siteID
        self.control = control
        self.sourceDirectory = sourceDirectory
        self.onLog = onLog
        self.exportAndImport = exportAndImport
    }

    /// Conforms to `MCPChannelResponder.Handler`'s shape; pass `persister.handle` directly to
    /// `MCPChannelResponder.init(connection:handler:)` in place of the bare `bridge.handle` P1
    /// wired.
    public func handle(_ message: JSONValue) async -> JSONValue? {
        guard let reply = await inner(message) else { return nil }
        guard let commit = Self.extractCommit(from: reply), ContainerEditExport.isPlausibleCommit(commit) else {
            return reply
        }
        do {
            try await exportAndImport(commit, siteID, control, sourceDirectory, onLog)
            return reply
        } catch {
            // `String(describing:)` for the internal log line only — it renders raw Swift enum
            // syntax (e.g. `syncFailed("...")`), useful for debugging but not fit for the
            // phone/client-facing message below, which uses `localizedDescription` instead.
            let logLine = "persist failed for commit \(commit): \(String(describing: error))"
            Self.report(logLine)
            // Also route through the caller-supplied sink (in production, `LogCenter` — see
            // `RemoteContainerSession`'s wiring): `Self.report` only reaches the system log and
            // this process's own stderr, neither of which a caller observing this actor's
            // injected `onLog` (e.g. a debug pane) would see.
            onLog(logLine, .stderr)
            return Self.errorResponse(
                replacing: reply,
                message: "the edit applied but could not be saved to Source: \(error.localizedDescription)")
        }
    }

    /// Extracts a `commit` from a raw JSON-RPC `tools/call` response object — mirrors
    /// `MCPApplyEditRouter.parseStructured`'s `content[0].text` JSON parse, but reads the full
    /// wire envelope (`{jsonrpc, id, result: {content, isError}}`) this bridge deals in, rather
    /// than an already-unwrapped `MCPClient.ToolCallResult`. Returns `nil` for a tool-level
    /// failure (`isError: true`) — nothing valid to export regardless of content text — or any
    /// shape that isn't a successful `tools/call` response carrying a `commit` string.
    static func extractCommit(from reply: JSONValue) -> String? {
        guard case .object(let root) = reply,
              case .object(let result)? = root["result"] else { return nil }
        if case .bool(true)? = result["isError"] { return nil }
        guard case .array(let content)? = result["content"] else { return nil }
        for item in content {
            guard case .object(let obj) = item,
                  case .string("text")? = obj["type"],
                  case .string(let text)? = obj["text"],
                  let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let commit = json["commit"] as? String, !commit.isEmpty
            else { continue }
            return commit
        }
        return nil
    }

    /// Builds a JSON-RPC error object carrying `reply`'s own request id — same shape
    /// `LoopbackMCPBridge.errorResponse` already uses for its own bridge-level failures.
    private static func errorResponse(replacing reply: JSONValue, message: String) -> JSONValue {
        let id: JSONValue = {
            if case .object(let obj) = reply, let id = obj["id"] { return id }
            return .null
        }()
        return .object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .int(-32000), "message": .string(message)]),
        ])
    }

    private static func report(_ message: String) {
        logger.error("HelperEditPersister: \(message, privacy: .public)")
        FileHandle.standardError.write(Data("HelperEditPersister: \(message)\n".utf8))
    }
}
