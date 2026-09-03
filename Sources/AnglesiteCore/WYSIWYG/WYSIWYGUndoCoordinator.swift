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
/// `UndoManager` usage for a redo-capable client.
@MainActor
public final class WYSIWYGUndoCoordinator {
    /// Replays one reversal step against the live canvas — the injected effect side. Typically
    /// `WYSIWYGCanvasController.apply(_:)`'s non-notifying twin (see that type's doc for why it
    /// must not be `submit(_:)` itself), awaited to completion. See `WYSIWYGPerformOutcome` for
    /// what the return value drives: `register`'s optimistic re-registration is corrected on
    /// `.applied(freshInverse:)` and rolled back entirely on `.rejected`.
    public typealias Performer = @MainActor (WYSIWYGReversal) async -> WYSIWYGPerformOutcome

    /// The focused window's undo manager. Weak: the window owns it.
    ///
    /// Deliberately **not** captured by `register(step:redoStep:)`'s registration closure — the
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
    /// 5). Cleared the instant an undo/redo actually fires (`register(step:redoStep:)`'s handler
    /// below), so coalescing never crosses that boundary.
    private var lastEditTextRegistration: (blockId: BlockId, previousRuns: [RichTextRun], token: Token)?

    /// Per-registration marker object, one per call to `register(step:redoStep:)`. `UndoManager`
    /// doesn't retain targets, so each token is kept alive for exactly as long as its stack entry
    /// exists by its own handler capturing it strongly (see `EditUndoCoordinator.Token` for the
    /// identical rationale). A *unique* token per registration — rather than reusing `self` as
    /// the target — is what makes one specific registration selectively removable via
    /// `removeAllActions(withTarget:)` without discarding every other pending undo/redo step for
    /// this coordinator; see `register(step:redoStep:)`'s rollback path.
    private final class Token {
        /// Set only when `perform` reports a `freshInverse` for the reversal THIS token's own
        /// registration performs (see `register(step:redoStep:)`'s `.applied(freshInverse:)`
        /// handling) — read by that same registration's handler in place of its originally
        /// captured `step`, the next time (and every time) it fires.
        ///
        /// This indirection exists because a correction can't take effect by removing this
        /// registration and creating a fresh one in its place, the seemingly obvious approach:
        /// `perform`'s result — and so the correction — is only known after an `await`, by which
        /// point `isUndoing`/`isRedoing` have already reverted to `false` (see
        /// `register(step:redoStep:)`'s doc comment on why the *optimistic* registration itself
        /// must happen synchronously, before any `await`, for the identical reason). A
        /// `registerUndo` call made post-`await` therefore always lands on whichever stack is
        /// current default (i.e. the undo stack) — verified empirically: correcting a
        /// redo-stack registration this way silently left `canRedo == false` instead of `true`.
        /// Mutating this field instead changes nothing about *when* the correction takes effect,
        /// only *which* reversal the already-correctly-placed registration performs — and that
        /// registration's handler only ever runs from inside a live `undo()`/`redo()` call, where
        /// the ambient flags are accurate again.
        var correctedStep: WYSIWYGReversal?
    }

    /// The in-flight `perform` spawned by the most recent undo/redo fire. Exposed for tests
    /// (and any other caller that needs to observe completion), which `await` it to see the
    /// conditional-registration-rollback/-correction behavior deterministically — mirrors
    /// `EditUndoCoordinator.pendingPerform`.
    private(set) var pendingPerform: Task<Void, Never>?

    public init(perform: @escaping Performer) {
        self.perform = perform
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
        let token = register(step: inverse, redoStep: .op(op))
        if case .editText(let blockId, _, let previousRuns) = op, let token {
            lastEditTextRegistration = (blockId, previousRuns, token)
        } else {
            lastEditTextRegistration = nil
        }
    }

    /// Registers `step` as the action a future `undo()`/`redo()` performs. When it fires:
    ///
    /// 1. **Synchronously**, before any `await`, re-registers `redoStep` as the next step in the
    ///    opposite direction (optimistically — see below). This has to happen synchronously:
    ///    `UndoManager.registerUndo` decides whether a registration lands on the undo or redo
    ///    stack from `isUndoing`/`isRedoing` *at the moment it's called*, and both flags revert to
    ///    `false` as soon as this handler's synchronous portion returns — well before an
    ///    unstructured `Task`'s body would actually run, even one with no real suspension inside
    ///    it. Registering only *after* `await`ing `perform` (the natural-looking ordering) always
    ///    lands the registration on the wrong stack in practice — verified empirically: with that
    ///    ordering, `canRedo` never becomes `true` after an undo, in both a bare synchronous
    ///    `Performer` and the real `WYSIWYGCanvasController`-backed one.
    /// 2. Only *then* asynchronously calls `perform(step)` — the actual document mutation.
    ///    - `.rejected`: the optimistic registration from step 1 is now describing a step that
    ///      never happened; it's removed via `removeAllActions(withTarget:)`, scoped to that one
    ///      registration's `Token` so nothing else already on either stack is disturbed.
    ///    - `.applied(freshInverse: someReversal)`: `someReversal` is the ACCURATE reversal of
    ///      what `step` just did — more accurate than the `redoStep` guess the optimistic
    ///      registration used, since it was computed by the transport against the post-write
    ///      tree (#1602 item 2). Stored on the optimistic registration's own `Token` as
    ///      `correctedStep` (see that type's doc comment for why this can't instead be a
    ///      remove-and-re-register, the way the rejection path just above handles its case) —
    ///      that registration's handler substitutes it for the originally captured `step` the
    ///      next time it fires.
    ///    - `.applied(freshInverse: nil)`: the transport had no better answer — leave the
    ///      optimistic registration exactly as it is (this is the ONLY outcome
    ///      `StubWYSIWYGHostTransport`-backed callers ever produce).
    ///
    /// Explicit group per registration: without one, `registerUndo` throws under
    /// `groupsByEvent = false` ("must begin a group before registering undo") — unit tests and
    /// any other run-loop-free caller set that, since no implicit event group is ever open. Under
    /// the app's default `groupsByEvent = true` this nests harmlessly inside the enclosing event
    /// group, same as `EditUndoCoordinator.registerApplied(_:)`.
    @discardableResult
    private func register(step: WYSIWYGReversal, redoStep: WYSIWYGReversal) -> Token? {
        guard let undoManager else { return nil }
        let token = Token()
        undoManager.beginUndoGrouping()
        // `token` is captured strongly by the handler on purpose — same reason as
        // `EditUndoCoordinator`'s own token capture: `UndoManager` holds its target
        // unsafely-unretained, so the capture pins `token` (and nothing else besides a weak
        // `self`) for exactly as long as this stack entry exists.
        undoManager.registerUndo(withTarget: token) { [weak self, token] _ in
            guard let self else { return }
            // `token.correctedStep`, when set, is a previous fire's server-corrected reversal for
            // this exact registration (see `Token`'s doc comment) — always preferred over the
            // `step` this closure originally captured.
            let stepToPerform = token.correctedStep ?? step
            // Finding 5: an undo/redo just fired — a same-block `editText` commit that arrives
            // after this point must start a fresh undo entry, never coalesce into whatever this
            // fire just put back on top of the stack.
            self.lastEditTextRegistration = nil
            let optimisticallyRegistered = self.register(step: redoStep, redoStep: stepToPerform)
            self.pendingPerform = Task { @MainActor [weak self] in
                guard let self else { return }
                switch await self.perform(stepToPerform) {
                case .rejected:
                    if let optimisticallyRegistered {
                        self.undoManager?.removeAllActions(withTarget: optimisticallyRegistered)
                    }
                case .applied(let freshInverse):
                    if let freshInverse, let optimisticallyRegistered {
                        optimisticallyRegistered.correctedStep = freshInverse
                    }
                }
                _ = token // keep the fired entry's own token referenced; see the capture-list comment above
            }
        }
        // Named while the group is still open — the name attaches to the open group; after
        // `endUndoGrouping` there may be no group left to attach to.
        undoManager.setActionName("Edit")
        undoManager.endUndoGrouping()
        return token
    }
}
#endif
