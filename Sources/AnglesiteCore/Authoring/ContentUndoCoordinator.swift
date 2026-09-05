// UndoManager is a Darwin-only Foundation type, so this bridge — used only by the app target's
// SiteWindowModel/SiteNavigatorModel — compiles out elsewhere, exactly like `EditUndoCoordinator`.
// See the cross-platform port design doc §5: a portable in-memory undo stack can slot in behind the
// same public API if/when a Linux/Windows GUI shell needs one.
#if canImport(Darwin)
import Foundation

/// Bridges *structural* content operations — New Page/Post/Collection entry/Component, Duplicate,
/// Delete, Rename — into a window's `UndoManager` so Edit ▸ Undo (⌘Z) and Edit ▸ Redo (⇧⌘Z)
/// reverse and replay them (#675).
///
/// Sibling of ``EditUndoCoordinator`` (#527), which covers assistant-applied *content* edits. The
/// two register into the same window `UndoManager` and interleave LIFO, as `UndoManager` does for
/// any set of clients. Both — and ``WYSIWYGUndoCoordinator`` — are thin `Op`-specific policies
/// over the shared `UndoBridge` (#1824); see that type for the token lifecycle, re-arm-on-outcome
/// rule, and undo/redo stack routing this coordinator relies on.
///
/// ## One record type for every operation
///
/// Every structural operation is a single-file content transition, so one ``Mutation`` — a
/// `(relativePath, before, after)` snapshot pair, `nil` meaning "the file does not exist" — covers
/// all of them:
///
/// | Operation      | `before`          | `after`           |
/// |----------------|-------------------|-------------------|
/// | New, Duplicate | `nil`             | created contents  |
/// | Delete         | captured contents | `nil`             |
/// | Rename         | pre-rewrite       | post-rewrite      |
///
/// Undo means *realize `before`*; redo means *realize `after`*, which is just undoing
/// ``Mutation/reversed``. There is no per-operation inverse logic anywhere — the injected
/// ``Applier`` only has to write contents or delete a file, which the app already does through
/// `ContentCreationWorkflow.restoreContent` / `.deleteContent`.
///
/// ## Policy notes
///
/// - **Redo works here** (unlike #527, whose reverse-apply is a sidecar git revert with no
///   re-apply primitive): every ``register(_:)`` also registers ``Mutation/reversed`` as the
///   bridge's optimistic opposite-direction step.
/// - **Failure re-arms ⌘Z, retry only.** ``ApplyOutcome/failed`` maps to `UndoBridge/Outcome/retry`:
///   the bridge drops the optimistically-registered inverse and, for a failed *undo*, re-registers
///   the original record so ⌘Z can retry — matching ``EditUndoCoordinator``'s retryable policy. A
///   failed *redo* can only be dropped (the bridge has no way to push onto the redo stack outside
///   an undo pass); see `UndoBridge` for why.
/// - **Groups only open outside undo/redo processing** — `shouldOpenGroup` at construction. Inside
///   a pass `UndoManager` has already opened the group for the opposite stack; nesting one within
///   it would attach `setActionName` to the *nested* group and leave Edit ▸ Redo reading a bare
///   "Redo".
/// - **Out-of-band invalidation.** Each record's bridge token is kept in `tokens` by id, so
///   ``invalidate(id:)`` removes exactly one record rather than clearing the stack.
///   ``invalidateAll()`` drops every pending record — call it when the window's site is replaced,
///   since paths and contents are site-relative.
@MainActor
public final class ContentUndoCoordinator {
    /// One structural operation, as a before/after snapshot of the single file it touched.
    public struct Mutation: Sendable, Equatable, Identifiable {
        /// Record identity. Not the path: a path can legitimately have several live records
        /// (create → delete → restore), and ``invalidate(id:)`` must remove exactly one.
        public let id: UUID
        /// The file the operation touched, relative to the site's `Source/` directory.
        public let relativePath: String
        /// Contents before the operation, or `nil` if the file did not exist. Undo realizes this.
        public let before: String?
        /// Contents after the operation, or `nil` if the operation deleted the file.
        public let after: String?
        /// Menu action name, e.g. `Delete “About”` → Edit ▸ Undo reads "Undo Delete “About”".
        /// Carried on the record so it survives onto the redo entry unchanged.
        public let actionName: String

        /// Creates a record; each property documents its own contract. `id` defaults to a fresh
        /// identity — every registration is a distinct record, including a ``reversed`` twin.
        public init(id: UUID = UUID(), relativePath: String, before: String?, after: String?, actionName: String) {
            self.id = id
            self.relativePath = relativePath
            self.before = before
            self.after = after
            self.actionName = actionName
        }

        /// The same transition read backwards — a fresh record (new ``id``) whose undo realizes
        /// this one's ``after``. Registered as the bridge's optimistic opposite-direction step.
        public var reversed: Mutation {
            Mutation(relativePath: relativePath, before: after, after: before, actionName: actionName)
        }
    }

    /// What happened when a popped record's apply resolved.
    public enum ApplyOutcome: Sendable, Equatable {
        /// ``Mutation/before`` is now on disk. The record is spent (its inverse is on the
        /// opposite stack).
        case applied
        /// The write or delete didn't happen (git refused, no site open, I/O error).
        case failed
    }

    /// Realizes `mutation.before` at `mutation.relativePath`: `nil` means delete the file,
    /// non-`nil` means write those exact bytes. Called on the main actor from a `Task` the
    /// bridge spawns when the user invokes Edit ▸ Undo or Edit ▸ Redo.
    public typealias Applier = @MainActor (Mutation) async -> ApplyOutcome

    /// The focused window's undo manager. Weak: the window owns it; this coordinator only
    /// registers into it. `nil` (no window attached yet) makes ``register(_:)`` a no-op.
    public weak var undoManager: UndoManager? {
        didSet { bridge.undoManager = undoManager }
    }

    private let bridge: UndoBridge<Mutation>
    /// Live registrations by record id, on either stack — mirrors the bridge's own tokens (kept
    /// current via the bridge's `onRegister`/`onFire` hooks, which reach every token the bridge
    /// creates, not just the ones from an explicit ``register(_:)`` call) so ``invalidate(id:)``/
    /// ``invalidateAll()`` can target one record without the bridge needing to know what an id
    /// even is.
    private var tokens: [UUID: UndoBridge<Mutation>.Token] = [:]

    /// The in-flight apply spawned by the most recent ⌘Z/⇧⌘Z. Exposed for tests, which `await` it
    /// to observe the settled stack state deterministically.
    var pendingApply: Task<Void, Never>? { bridge.pendingPerform }

    /// Creates a coordinator that realizes popped records through `apply`. Attach
    /// ``undoManager`` separately — the coordinator is typically built before the window (and
    /// therefore its undo manager) exists, and registration is a safe no-op until one is set.
    public init(apply: @escaping Applier) {
        bridge = UndoBridge(
            perform: { mutation in await apply(mutation) == .applied ? .succeeded : .retry },
            shouldOpenGroup: { undoManager in !undoManager.isUndoing && !undoManager.isRedoing }
        )
    }

    /// Registers a completed structural operation. Call at operation time, right after the write
    /// lands. No-op when no ``undoManager`` is attached.
    public func register(_ mutation: Mutation) {
        bridge.register(
            mutation, redo: mutation.reversed, actionName: mutation.actionName,
            onRegister: { [weak self] op, token in self?.tokens[op.id] = token },
            onFire: { [weak self] fired in self?.tokens[fired.id] = nil }
        )
    }

    /// Removes a still-pending record from either stack — call when the record can no longer be
    /// meaningfully applied. No-op for unknown or already-fired records.
    public func invalidate(id: UUID) {
        guard let token = tokens.removeValue(forKey: id) else { return }
        bridge.remove(token)
    }

    /// Drops every pending record — call when the window's site changes, since every record's
    /// path and contents belong to the site it was captured from.
    public func invalidateAll() {
        for token in tokens.values {
            bridge.remove(token)
        }
        tokens.removeAll()
    }

    // MARK: - Action names

    /// Menu action name for creating `displayName`: "New Page" → the menu reads "Undo New Page".
    /// Plain (unlocalized) strings, matching ``EditUndoCoordinator/actionName(for:)`` — and kept
    /// here rather than in the app target so they stay out of `check-localization-catalog.sh`'s
    /// `Sources/AnglesiteApp` scan, which has no way to see through `setActionName`'s `String`.
    public static func createActionName(_ displayName: String) -> String { "New \(displayName)" }

    /// Menu action name for a duplicate: "Duplicate “About”".
    public static func duplicateActionName(_ title: String) -> String { "Duplicate \(quoted(title))" }

    /// Menu action name for a delete: "Delete “About”".
    public static func deleteActionName(_ title: String) -> String { "Delete \(quoted(title))" }

    /// Menu action name for a rename. The *new* title is deliberately absent: the record is
    /// applied in both directions and naming one end would read backwards after a redo.
    public static func renameActionName() -> String { "Rename" }

    private static func quoted(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Item" : "\u{201C}\(trimmed)\u{201D}"
    }
}
#endif
