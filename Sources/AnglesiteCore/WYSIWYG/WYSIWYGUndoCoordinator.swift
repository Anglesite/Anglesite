// UndoManager is a Darwin-only Foundation type — see EditUndoCoordinator.swift's header for the
// same rationale; this coordinator compiles out on non-Darwin for the identical reason.
#if canImport(Darwin)
import Foundation

/// Bridges applied WYSIWYG ops into a window's `UndoManager` with **real redo** — unlike
/// `EditUndoCoordinator` (git-revert LIFO, no redo), every op ships its own inverse (spec §3.2),
/// so undoing an action re-registers the forward op as the next redo/undo step: standard
/// `UndoManager` usage for a redo-capable client.
@MainActor
public final class WYSIWYGUndoCoordinator {
    /// Applies one op against the live canvas — the injected effect side. Typically
    /// `WYSIWYGCanvasController.submit(_:)`'s non-notifying twin (see that type's doc for why it
    /// must not be `submit(_:)` itself), awaited to completion and collapsed to whether the op
    /// actually landed (`true`) or was rejected (`false`, e.g. a version-mismatch conflict). The
    /// `Bool` return is load-bearing: `register(op:redoOp:)` rolls back its *optimistic*
    /// registration of the opposite direction when this reports `false`, so a rejected op doesn't
    /// leave a stale, now-wrong undo/redo step on the stack (a real document round trip, not a
    /// same-thread revert — see `EditUndoCoordinator` for the analogous "failure re-arms instead
    /// of pretending it happened" policy).
    public typealias Performer = @MainActor (Op) async -> Bool

    /// The focused window's undo manager. Weak: the window owns it.
    ///
    /// Deliberately **not** captured by `register(op:redoOp:)`'s registration closure — the
    /// closure re-reads this property each time it needs the manager instead. Capturing the
    /// `UndoManager` instance directly in the closure would create a retain cycle: the closure is
    /// itself held by that same `UndoManager`'s undo stack, and since every fire re-registers the
    /// opposite direction, an entry (and the cycle) is always live after the first edit.
    public weak var undoManager: UndoManager?

    private let perform: Performer

    /// The most-recently-registered `editText`'s block id, session baseline (`previousRuns` — the
    /// design doc says: fixed for a whole `RichTextEditor.enter()` session, see that type's header
    /// comment, so it's identical across every debounced commit in that session), and `Token` —
    /// used by `registerApplied(op:inverse:)` to coalesce a burst of same-session debounced
    /// commits into a single undo entry ("typing coalescing"; #1225 final-review fix wave, Finding
    /// 5). Cleared the instant an undo/redo actually fires (`register(op:redoOp:)`'s handler
    /// below), so coalescing never crosses that boundary.
    private var lastEditTextRegistration: (blockId: BlockId, previousRuns: [RichTextRun], token: Token)?

    /// Per-registration marker object, one per call to `register(op:redoOp:)`. `UndoManager`
    /// doesn't retain targets, so each token is kept alive for exactly as long as its stack entry
    /// exists by its own handler capturing it strongly (see `EditUndoCoordinator.Token` for the
    /// identical rationale). A *unique* token per registration — rather than reusing `self` as
    /// the target — is what makes one specific registration selectively removable via
    /// `removeAllActions(withTarget:)` without discarding every other pending undo/redo step for
    /// this coordinator; see `register(op:redoOp:)`'s rollback path.
    private final class Token {}

    /// The in-flight `perform` spawned by the most recent undo/redo fire. Exposed for tests
    /// (and any other caller that needs to observe completion), which `await` it to see the
    /// conditional-registration-rollback behavior deterministically — mirrors
    /// `EditUndoCoordinator.pendingPerform`.
    private(set) var pendingPerform: Task<Void, Never>?

    public init(perform: @escaping Performer) {
        self.perform = perform
    }

    /// Registers one applied op on the undo stack. Call from
    /// `WYSIWYGCanvasController.onOpApplied`, right after a real, already-confirmed success —
    /// this entry point never calls `perform` itself, it only records the step. No-op when no
    /// `undoManager` is attached.
    public func registerApplied(op: Op, inverse: Op) {
        // Typing coalescing (design doc; #1225 final-review fix wave, Finding 5): without this, a
        // long typing session emitted one undo entry per debounced commit, every one of them
        // sharing the SAME `enter()`-time baseline as `previousRuns` — so N stacked undo entries
        // that don't individually do anything a user would recognize as "one edit."
        //
        // When the incoming op is another `editText` on the SAME block, with the SAME
        // `previousRuns` as the most-recently-registered entry, replace that entry instead of
        // stacking a new one (same `Token`-scoped `removeAllActions(withTarget:)` pattern the
        // rejected-perform rollback below already uses). This is correct, not just convenient: the
        // new `op`'s own `previousRuns` already IS the session's true original baseline (unchanged
        // since `enter()`, since `RichTextEditor.#commit` always builds `previousRuns` from the
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
            undoManager?.removeAllActions(withTarget: last.token)
        }
        let token = register(op: inverse, redoOp: op)
        if case .editText(let blockId, _, let previousRuns) = op, let token {
            lastEditTextRegistration = (blockId, previousRuns, token)
        } else {
            lastEditTextRegistration = nil
        }
    }

    /// Registers `op` as the action a future `undo()`/`redo()` performs. When it fires:
    ///
    /// 1. **Synchronously**, before any `await`, re-registers `redoOp` as the next step in the
    ///    opposite direction (optimistically — see below). This has to happen synchronously:
    ///    `UndoManager.registerUndo` decides whether a registration lands on the undo or redo
    ///    stack from `isUndoing`/`isRedoing` *at the moment it's called*, and both flags revert to
    ///    `false` as soon as this handler's synchronous portion returns — well before an
    ///    unstructured `Task`'s body would actually run, even one with no real suspension inside
    ///    it. Registering only *after* `await`ing `perform` (the natural-looking ordering) always
    ///    lands the registration on the wrong stack in practice — verified empirically: with that
    ///    ordering, `canRedo` never becomes `true` after an undo, in both a bare synchronous
    ///    `Performer` and the real `WYSIWYGCanvasController`-backed one.
    /// 2. Only *then* asynchronously calls `perform(op)` — the actual document mutation. If it
    ///    reports the op didn't land, the optimistic registration from step 1 is now describing a
    ///    step that never happened; it's removed via `removeAllActions(withTarget:)`, scoped to
    ///    that one registration's `Token` so nothing else already on either stack is disturbed.
    ///
    /// Explicit group per registration: without one, `registerUndo` throws under
    /// `groupsByEvent = false` ("must begin a group before registering undo") — unit tests and
    /// any other run-loop-free caller set that, since no implicit event group is ever open. Under
    /// the app's default `groupsByEvent = true` this nests harmlessly inside the enclosing event
    /// group, same as `EditUndoCoordinator.registerApplied(_:)`.
    @discardableResult
    private func register(op: Op, redoOp: Op) -> Token? {
        guard let undoManager else { return nil }
        let token = Token()
        undoManager.beginUndoGrouping()
        // `token` is captured strongly by the handler on purpose — same reason as
        // `EditUndoCoordinator`'s own token capture: `UndoManager` holds its target
        // unsafely-unretained, so the capture pins `token` (and nothing else besides a weak
        // `self`) for exactly as long as this stack entry exists.
        undoManager.registerUndo(withTarget: token) { [weak self, token] _ in
            guard let self else { return }
            // Finding 5: an undo/redo just fired — a same-block `editText` commit that arrives
            // after this point must start a fresh undo entry, never coalesce into whatever this
            // fire just put back on top of the stack.
            self.lastEditTextRegistration = nil
            let optimisticallyRegistered = self.register(op: redoOp, redoOp: op)
            self.pendingPerform = Task { @MainActor [weak self] in
                guard let self else { return }
                if await self.perform(op) == false, let optimisticallyRegistered {
                    self.undoManager?.removeAllActions(withTarget: optimisticallyRegistered)
                }
            }
            _ = token // keep the fired entry's own token referenced; see the capture-list comment above
        }
        // Named while the group is still open — the name attaches to the open group; after
        // `endUndoGrouping` there may be no group left to attach to.
        undoManager.setActionName("Edit")
        undoManager.endUndoGrouping()
        return token
    }
}
#endif
