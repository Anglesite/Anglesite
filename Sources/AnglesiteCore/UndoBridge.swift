// UndoManager is a Darwin-only Foundation type — see EditUndoCoordinator.swift's header for the
// shared rationale; this bridge compiles out on non-Darwin for the identical reason.
#if canImport(Darwin)
import Foundation

/// The shared machinery behind ``ContentUndoCoordinator``, ``EditUndoCoordinator`` and
/// ``WYSIWYGUndoCoordinator`` (#1824): registering one `Op` on a window `UndoManager`, replaying
/// it on undo/redo, and re-arming or correcting the entry from an async outcome. Each coordinator
/// reduces to its own `Op` type, an `Outcome`-mapping `perform` closure, and a couple of policy
/// closures/parameters; everything about *how* an entry survives a round trip through
/// `UndoManager` lives here once.
///
/// ## The `register(_:redo:actionName:onFire:)` contract
///
/// `register(op, redo: redoOp, ...)` puts `op` on whichever stack `UndoManager` currently expects
/// (the undo stack outside undo/redo processing; the opposite stack from whichever one is
/// currently being processed). When it fires:
///
/// 1. **Synchronously**, before any `await`, `redoOp` (when non-nil) is optimistically
///    re-registered as the next step in the *opposite* direction — this has to happen
///    synchronously because `UndoManager.registerUndo` decides which stack a registration lands
///    on from `isUndoing`/`isRedoing` at the moment it's called, and both flags revert to `false`
///    the instant this handler's synchronous portion returns, well before an unstructured
///    `Task`'s body actually runs. Registering only after `await`ing `perform` always lands on
///    the wrong stack in practice (verified empirically against a bare synchronous `Performer`
///    and a real transport-backed one, prior to this unification).
/// 2. **Asynchronously**, `perform(op)` runs the real effect and reports an ``Outcome``:
///    - `.succeeded`: the optimistic registration from step 1 stands as-is.
///    - `.corrected(fresh)`: the optimistic registration's own step is replaced by `fresh` — an
///      in-place mutation (not remove-and-re-register), because by the time this resolves
///      `isUndoing`/`isRedoing` are already back to `false`, so a fresh `registerUndo` call here
///      would land on the wrong stack. See ``Token``.
///    - `.rejected`: the optimistic registration is removed — `op` never happened, so its inverse
///      describes a transition that never occurred.
///    - `.retry`: the optimistic registration (if any) is removed, and `op` itself is
///      re-registered **only when it fired from the undo direction** (`wasUndo`). `UndoManager`
///      exposes no way to push onto the redo stack outside an undo pass, so a failed *redo* can
///      only be dropped, not migrated onto the undo stack as a lie about what's on disk/state.
///
/// `redoOp == nil` opts a coordinator out of redo entirely (``EditUndoCoordinator``): nothing is
/// ever optimistically registered, and `.retry` becomes an unconditional re-arm since every fire
/// is, by construction, an undo.
///
/// `onRegister` and `onFire`, when supplied, run synchronously — the instant a new token is
/// created, and the instant any entry fires (including recursively re-registered ones) before the
/// async `perform` call — and are threaded through every recursive registration this bridge makes
/// on an entry's behalf (the optimistic opposite-direction step, a `.retry` re-arm). Coordinators
/// use these for their own bookkeeping this bridge has no reason to know about: id-keyed token
/// maps for ``ContentUndoCoordinator``/``EditUndoCoordinator``'s `invalidate`/`invalidateAll` —
/// which must reach *every* live token, not just the ones created by an explicit external
/// `register` call — and typing-coalescing state for ``WYSIWYGUndoCoordinator``.
///
/// `shouldOpenGroup`, fixed at construction, is the one piece of `UndoManager` grouping policy
/// that varies: most coordinators always open an explicit group per registration (`{ _ in true }`,
/// required under `groupsByEvent = false` — see the coordinators' own tests), but
/// ``ContentUndoCoordinator`` opens one only outside undo/redo processing, since inside a pass
/// `UndoManager` has already opened the group for the opposite stack and nesting one would attach
/// `setActionName` to the wrong group.
@MainActor
final class UndoBridge<Op: Sendable> {
    /// What happened when a popped entry's `perform` resolved.
    enum Outcome: Sendable {
        /// `op` happened. Any optimistic opposite-direction registration stands as-is.
        case succeeded
        /// `op` happened, and `fresh` is a more accurate description of the opposite-direction
        /// step than the one optimistically registered for it — substituted in place.
        case corrected(Op)
        /// `op` didn't happen and can't be retried. Any optimistic registration is dropped;
        /// nothing is re-armed.
        case rejected
        /// `op` didn't happen but might later. Any optimistic registration is dropped; `op`
        /// itself is re-armed if it fired from the undo direction (see the type's doc comment).
        case retry
    }

    /// Runs the real effect for a popped entry and reports what happened. Called on the main
    /// actor from a `Task` spawned the instant `op` fires.
    typealias Perform = @MainActor (Op) async -> Outcome

    /// Per-registration target. `UndoManager` does not retain targets, so each token is kept
    /// alive by its own handler capturing it strongly — its lifetime is exactly the lifetime of
    /// its stack entry. `op` is `var`, not `let`: `.corrected(_:)` mutates it in place so the
    /// entry's own (already-registered, already stack-placed) handler picks up the correction the
    /// next time it fires, reading `token.op` fresh rather than a value closed over at
    /// registration time.
    final class Token {
        fileprivate var op: Op
        fileprivate init(_ op: Op) { self.op = op }
    }

    /// The focused window's undo manager. Weak: the window owns it; the bridge only registers
    /// into it. `nil` makes ``register(_:redo:actionName:onFire:)`` a no-op.
    weak var undoManager: UndoManager?

    private let perform: Perform
    private let shouldOpenGroup: (UndoManager) -> Bool
    /// The in-flight `perform` spawned by the most recent fire. Exposed for tests (via each
    /// coordinator's own forwarding property), which `await` it to observe the settled stack
    /// state deterministically.
    private(set) var pendingPerform: Task<Void, Never>?

    init(
        perform: @escaping Perform,
        shouldOpenGroup: @escaping (UndoManager) -> Bool = { _ in true }
    ) {
        self.perform = perform
        self.shouldOpenGroup = shouldOpenGroup
    }

    /// Registers `op` as the action a future `undo()`/`redo()` performs, with `redoOp` — when
    /// non-nil — optimistically registered in the opposite direction the instant `op` fires. See
    /// the type's doc comment for the full firing sequence, and for `onRegister`/`onFire`.
    /// Returns the token backing the registration, or `nil` when no ``undoManager`` is attached.
    @discardableResult
    func register(
        _ op: Op,
        redo redoOp: Op?,
        actionName: String,
        onRegister: ((Op, Token) -> Void)? = nil,
        onFire: ((Op) -> Void)? = nil
    ) -> Token? {
        guard let undoManager else { return nil }
        let token = Token(op)
        onRegister?(op, token)
        let opensGroup = shouldOpenGroup(undoManager)
        if opensGroup { undoManager.beginUndoGrouping() }
        // `token` is captured strongly on purpose: UndoManager holds its target
        // unsafely-unretained, so the capture pins the token (and nothing else — self is weak)
        // for exactly as long as the stack entry exists.
        undoManager.registerUndo(withTarget: token) { [weak self, token] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let firedOp = token.op
                onFire?(firedOp)
                // Captured before the optimistic registration below (which doesn't change either
                // flag) so `.retry` knows which direction this entry fired from.
                let wasUndo = undoManager.isUndoing
                let optimistic = redoOp.flatMap {
                    self.register($0, redo: firedOp, actionName: actionName, onRegister: onRegister, onFire: onFire)
                }
                self.pendingPerform = Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch await self.perform(firedOp) {
                    case .succeeded:
                        break
                    case .corrected(let fresh):
                        optimistic?.op = fresh
                    case .rejected:
                        if let optimistic { self.remove(optimistic) }
                    case .retry:
                        if let optimistic { self.remove(optimistic) }
                        guard wasUndo else { return }
                        self.register(firedOp, redo: redoOp, actionName: actionName, onRegister: onRegister, onFire: onFire)
                    }
                }
            }
        }
        undoManager.setActionName(actionName)
        if opensGroup { undoManager.endUndoGrouping() }
        return token
    }

    /// Removes a still-pending entry from whichever stack it's on — a no-op once it has fired.
    func remove(_ token: Token) {
        undoManager?.removeAllActions(withTarget: token)
    }
}
#endif
