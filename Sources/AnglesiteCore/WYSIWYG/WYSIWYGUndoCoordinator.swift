// UndoManager is a Darwin-only Foundation type — see EditUndoCoordinator.swift's header for the
// same rationale; this coordinator compiles out on non-Darwin for the identical reason.
#if canImport(Darwin)
import Foundation

/// What a `WYSIWYGUndoCoordinator.Performer` reports back after replaying one `WYSIWYGReversal`.
public enum WYSIWYGPerformOutcome: Sendable {
    /// The replay was refused (e.g. a version-mismatch conflict) — nothing changed.
    case rejected
    /// The replay landed. `freshInverse`, when non-nil, is the accurate reversal of what was
    /// just performed — computed by the transport against the post-write tree (#1602 item 2).
    /// `nil` means the transport has no better answer than the client-computed guess already
    /// registered as the next undo/redo step (e.g. `StubWYSIWYGHostTransport`, or the rare op
    /// family the sidecar doesn't compute an inverse for) — the existing optimistic registration
    /// is left as-is in that case.
    case applied(freshInverse: WYSIWYGReversal?)
}

/// Bridges applied WYSIWYG ops into a window's `UndoManager` with **real redo** — unlike
/// `EditUndoCoordinator` (git-revert LIFO, no redo), every op ships its own inverse (spec §3.2),
/// so undoing an action re-registers the forward op as the next redo/undo step: standard
/// `UndoManager` usage for a redo-capable client. Sibling of ``ContentUndoCoordinator`` and
/// ``EditUndoCoordinator`` (#1824): the token lifecycle, re-arm-on-outcome rule, and undo/redo
/// stack routing all live in the shared `UndoBridge` — this type adds only the `Op`/
/// `WYSIWYGReversal` outcome mapping and typing-coalescing policy on top.
@MainActor
public final class WYSIWYGUndoCoordinator {
    /// Replays one reversal step against the live canvas — the injected effect side. Typically
    /// `WYSIWYGCanvasController.apply(_:)` — `submit(_:)`'s non-notifying twin (see that type's
    /// doc for why this must not be `submit(_:)` itself), awaited to completion. See
    /// `WYSIWYGPerformOutcome` for what the return value drives: an optimistic
    /// opposite-direction registration is corrected on `.applied(freshInverse:)` and rolled back
    /// entirely on `.rejected`.
    public typealias Performer = @MainActor (WYSIWYGReversal) async -> WYSIWYGPerformOutcome

    /// The focused window's undo manager. Weak: the window owns it.
    public weak var undoManager: UndoManager? {
        didSet { bridge.undoManager = undoManager }
    }

    private let bridge: UndoBridge<WYSIWYGReversal>

    /// The most-recently-registered `editText`'s block id, session baseline (`previousRuns` — the
    /// design doc says: fixed for a whole `RichTextEditor.enter()` session, see that type's header
    /// comment, so it's identical across every debounced commit in that session), and bridge
    /// token — used by `registerApplied(op:inverse:)` to coalesce a burst of same-session
    /// debounced commits into a single undo entry ("typing coalescing"; #1225 final-review fix
    /// wave, Finding 5). Cleared the instant an undo/redo actually fires (via the bridge's
    /// `onFire`, passed to every registration below), so coalescing never crosses that boundary.
    private var lastEditTextRegistration: (blockId: BlockId, previousRuns: [RichTextRun], token: UndoBridge<WYSIWYGReversal>.Token)?

    public init(perform: @escaping Performer) {
        bridge = UndoBridge { reversal in
            switch await perform(reversal) {
            case .rejected:
                return .rejected
            case .applied(let freshInverse):
                guard let freshInverse else { return .succeeded }
                return .corrected(freshInverse)
            }
        }
    }

    /// Registers one applied op on the undo stack. Call from
    /// `WYSIWYGCanvasController`'s applied-op listener list (`addOpAppliedListener`/
    /// `fireOpApplied`), right after a real, already-confirmed success —
    /// this entry point never calls `perform` itself, it only records the step. No-op when no
    /// `undoManager` is attached.
    ///
    /// `op` stays a plain `Op` — it's the forward direction the user just successfully submitted
    /// against an in-sync model, so its embedded ids are valid at the moment of registration (no
    /// id-drift concern there). `inverse` is a `WYSIWYGReversal` because the UNDO direction is
    /// exactly where #1602 item 2's id-drift bug lives: whenever the applying transport reported a
    /// server-computed `WireInverse` (Task 5), the caller passes `.wire(_:)` here instead of
    /// `.op(WYSIWYGOpInverter.invert(op))`.
    public func registerApplied(op: Op, inverse: WYSIWYGReversal) {
        // Typing coalescing (design doc; #1225 final-review fix wave, Finding 5): without this, a
        // long typing session emitted one undo entry per debounced commit, every one of them
        // sharing the SAME `enter()`-time baseline as `previousRuns` — so N stacked undo entries
        // that don't individually do anything a user would recognize as "one edit."
        //
        // When the incoming op is another `editText` on the SAME block, with the SAME
        // `previousRuns` as the most-recently-registered entry, replace that entry instead of
        // stacking a new one. This is correct, not just convenient: the new `op`'s own
        // `previousRuns` already IS the session's true original baseline (unchanged since
        // `enter()`, since `RichTextEditor.#commit` always builds `previousRuns` from the
        // session's fixed baseline, not the prior debounce tick), so nothing from the replaced
        // registration needs to be preserved — its `inverse` would have restored to that exact
        // same baseline anyway.
        //
        // Comparing `previousRuns` (not just `blockId`) is load-bearing: two genuinely SEPARATE
        // sessions on the same block (edit, click away, come back, edit again) would otherwise
        // still match on `blockId` alone, and blindly replacing would silently truncate undo
        // history — the first session's edit would become unrecoverable through Undo. A second
        // session's `previousRuns` is whatever the first session's LAST commit's `runs` was
        // (`enter()` re-reads the live model at entry), which only coincidentally equals the
        // stored baseline, so this check reliably tells the two cases apart.
        if case .editText(let blockId, _, let previousRuns) = op,
           let last = lastEditTextRegistration, last.blockId == blockId, last.previousRuns == previousRuns {
            bridge.remove(last.token)
        }
        let token = bridge.register(
            inverse, redo: .op(op), actionName: "Edit",
            onFire: { [weak self] _ in self?.lastEditTextRegistration = nil }
        )
        if case .editText(let blockId, _, let previousRuns) = op, let token {
            lastEditTextRegistration = (blockId, previousRuns, token)
        } else {
            lastEditTextRegistration = nil
        }
    }

    /// The in-flight `perform` spawned by the most recent undo/redo fire. Exposed for tests
    /// (and any other caller that needs to observe completion), which `await` it to see the
    /// conditional-registration-rollback/-correction behavior deterministically — mirrors
    /// `EditUndoCoordinator.pendingPerform`.
    var pendingPerform: Task<Void, Never>? { bridge.pendingPerform }
}
#endif
