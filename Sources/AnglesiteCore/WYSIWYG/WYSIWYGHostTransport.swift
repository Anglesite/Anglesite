import Foundation

/// Host -> engine seam (spec §3.2/§3.3), Swift-side counterpart to
/// `JS/wysiwyg-engine/src/types.ts`'s `HostTransport`. `StubWYSIWYGHostTransport` implements it
/// against an in-memory model for now; a real sidecar-backed implementation lands once #1222
/// unblocks.
public protocol WYSIWYGHostTransport: Sendable {
    func sendOp(_ envelope: OpEnvelope) async -> OpResult
    /// Host-initiated model push — a re-render notification, e.g. after an outside hand edit.
    /// Returns an unsubscribe closure.
    ///
    /// `async` (unlike the JS `HostTransport.onModelUpdate`'s synchronous signature) because a
    /// realistic conforming type is actor-isolated: registering the listener has to happen inside
    /// that isolation domain before the unsubscribe closure is handed back, and a plain
    /// `nonisolated` requirement can't guarantee that ordering without racing the caller.
    func onModelUpdate(_ listener: @escaping @Sendable (BlockModel) -> Void) async -> () -> Void
}

/// The server's own computed reversal for one applied WYSIWYG edit (`anglesite-skills#435`) —
/// the wire op name + payload to send back through `EditRouter.apply(_:)` verbatim, bypassing
/// `WYSIWYGOpTranslator`/`ComponentStructureEditBuilder` entirely. Computed by the sidecar
/// against the file's POST-write tree, so — unlike a locally-computed `WYSIWYGOpInverter.invert`
/// result — its embedded node ids stay correct even though the sidecar renumbers every node on
/// each re-parse (see `docs/superpowers/plans/2026-09-02-wysiwyg-undo-correctness-and-component-insert.md`'s
/// design decision 3, which reverses
/// `docs/superpowers/plans/2026-08-19-wysiwyg-sidecar-backed-transport.md`'s design decision 1).
public struct WireInverse: Sendable, Equatable {
    /// The wire op name to replay (e.g. `"deleteBlock"`).
    public let op: String
    /// The wire's `component` payload, verbatim — already includes a fresh `baseVersion`
    /// stamped by the sidecar against the file's post-write hash (`apply-edit-dispatcher.mjs`).
    public let component: JSONValue

    public init(op: String, component: JSONValue) {
        self.op = op
        self.component = component
    }
}

/// One undo/redo stack entry's reversal step: either a plain ``Op`` (translated fresh via
/// `WYSIWYGOpTranslator` against whatever ids it embeds — the only kind `WYSIWYGOpInverter.invert`
/// can ever produce, and the only kind a non-sidecar transport like `StubWYSIWYGHostTransport`
/// supports), or a ``WireInverse`` (replayed verbatim, bypassing the `Op`/translator layer
/// entirely). `WYSIWYGUndoCoordinator` stores this instead of a bare `Op` so a transport
/// conforming to ``WYSIWYGServerInvertibleTransport`` can supply an always-correct reversal
/// instead of a client-guessed one.
public enum WYSIWYGReversal: Sendable, Equatable {
    case op(Op)
    case wire(WireInverse)
}

/// Optional transport capability: alongside the usual ``WYSIWYGHostTransport/sendOp(_:)``, also
/// reports the server-computed ``WireInverse`` for the op it just applied, and can replay a
/// previously-reported ``WireInverse`` directly to undo/redo it. Only `SidecarWYSIWYGHostTransport`
/// conforms — `StubWYSIWYGHostTransport` has no real backing store to compute one against, so
/// callers must fall back to `WYSIWYGOpInverter`'s client-computed inverse when a transport isn't
/// this type, or when a specific reply doesn't carry one.
public protocol WYSIWYGServerInvertibleTransport: WYSIWYGHostTransport {
    /// Like `sendOp(_:)`, but also returns the server-computed reversal for `envelope.op`, when
    /// the applied reply carried one (in practice every WYSIWYG structural/text/token op does —
    /// see `anglesite-skills/server/component-structure-edit.mjs`/`design-token-edit.mjs` — so
    /// `nil` alongside `.applied` should be rare, but is handled, not assumed impossible). `nil`
    /// on a `.rejected` result (nothing was applied to invert).
    func sendOpReportingServerInverse(_ envelope: OpEnvelope) async -> (result: OpResult, serverInverse: WireInverse?)

    /// Replays `inverse` verbatim via the underlying `EditRouter` (using `requestId` as the
    /// replayed `EditMessage`'s correlation id), bypassing `WYSIWYGOpTranslator` entirely, then
    /// re-fetches + adapts the model exactly like `sendOp(_:)`'s `.applied` path. Returns the SAME
    /// `(result, serverInverse)` shape as `sendOpReportingServerInverse` so an undo/redo chain
    /// keeps self-correcting: on success, `serverInverse` is THIS call's own freshly-computed
    /// reversal — the accurate way to reverse what replaying `inverse` just did — used to correct
    /// whatever gets registered as the next undo/redo step.
    func applyServerInverse(_ inverse: WireInverse, requestId: String) async -> (result: OpResult, serverInverse: WireInverse?)
}
