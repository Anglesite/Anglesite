// UndoManager is a Darwin-only Foundation type, so this bridge — used only by the app target's
// ChatModel — compiles out elsewhere. No non-Darwin consumer exists yet (see the cross-platform
// port design doc §5); a portable in-memory undo stack can slot in behind the same public API
// if/when a Linux/Windows GUI shell needs one.
#if canImport(Darwin)
import Foundation

/// Bridges app-applied edits into a window's `UndoManager` so Edit ▸ Undo (⌘Z) reverses them (#527).
///
/// This sits at the shared edit-pipeline level, not inside any one assistant: every applied
/// edit with a commit — overlay drops, chat/assistant tool edits, alt-text follow-ups — flows
/// through `MCPApplyEditRouter.onEdit` into the app's edit recorder, which registers a
/// ``Record`` here at apply time. The reverse-apply itself is the plugin's git-revert
/// (`undo_edit`, wrapped by ``UndoCommand``), so the record only needs the commit SHA (the
/// stable identity of the edit — chat rows are re-created with fresh UUIDs on every history
/// reload) plus the file path for the menu action name. The injected ``Performer`` delegates
/// to the existing inverse-application + conflict-detection path (`ChatModel.undoEdit`).
///
/// The app-target glue stays thin: set ``undoManager`` from SwiftUI's
/// `@Environment(\.undoManager)` and supply `perform`; everything else lives here where it's
/// unit-testable against a plain Foundation `UndoManager`. This coordinator — and its siblings
/// ``ContentUndoCoordinator`` and ``WYSIWYGUndoCoordinator`` — are thin `Op`-specific policies
/// over the shared `UndoBridge` (#1824); see that type for the token lifecycle,
/// re-arm-on-outcome rule, and undo/redo stack routing this coordinator relies on.
///
/// Policy notes:
/// - **No redo.** The plugin exposes revert (`undo_edit`) but no re-apply primitive, so this
///   coordinator passes `redo: nil` to the bridge — nothing ever lands on the redo stack, and
///   after a successful ⌘Z, Edit ▸ Redo stays disabled.
/// - **Retryable re-arms; stale doesn't.** ``UndoOutcome/retryable`` maps to
///   `UndoBridge/Outcome/retry`, which — since every fire here is an undo (no redo entry ever
///   exists) — unconditionally re-registers the record so ⌘Z can retry, symmetric with the chat
///   row's Undo button, which also keeps its entry on failure. ``UndoOutcome/stale`` maps to
///   `UndoBridge/Outcome/rejected`: consumed without re-arming.
/// - **LIFO matches git.** `UndoManager` pops newest-first, which is exactly the head-first
///   order the edits branch wants reverts in.
/// - **Out-of-band undos invalidate their record.** When an edit is undone by another path
///   (the chat row's Undo button), call ``invalidate(commit:)`` so ⌘Z doesn't replay a stale
///   action; when the transcript is cleared wholesale (reset conversation), call
///   ``invalidateAll()``.
@MainActor
public final class EditUndoCoordinator {
    /// One applied edit, as registered on the undo stack.
    public struct Record: Sendable, Equatable {
        /// Source file the edit landed on (site-relative path). Drives the menu action name.
        public let file: String
        /// SHA of the commit on `refs/heads/anglesite/edits` that captures this edit — the
        /// record's identity. Stable across transcript reloads, unlike chat-row UUIDs.
        public let commit: String

        /// Memberwise initializer — built by the edit recorder from the applied reply's
        /// `file` + `commit` pair.
        public init(file: String, commit: String) {
            self.file = file
            self.commit = commit
        }
    }

    /// What actually happened when a popped record's reverse-apply resolved.
    public enum UndoOutcome: Sendable, Equatable {
        /// The edit was reverted. The record is spent.
        case undone
        /// The revert didn't happen but could later (MCP error, conflict sheet cancelled,
        /// MCP not running). The coordinator re-registers the record so ⌘Z can retry.
        case retryable
        /// The record no longer maps to an undoable edit (row gone or already undone via
        /// another path). Dropped without re-registering.
        case stale
    }

    /// Runs the reverse-apply for one record and reports what happened. Called on the main
    /// actor from a `Task` the bridge spawns when the user invokes Edit ▸ Undo.
    public typealias Performer = @MainActor (Record) async -> UndoOutcome

    /// The focused window's undo manager. Weak: the window owns it; this coordinator only
    /// registers into it. `nil` (no window attached yet) makes ``registerApplied(_:)`` a no-op.
    public weak var undoManager: UndoManager? {
        didSet { bridge.undoManager = undoManager }
    }

    private let bridge: UndoBridge<Record>
    /// Live registrations by commit SHA, mirroring the bridge's own tokens (kept current via the
    /// bridge's `onRegister`/`onFire` hooks, which reach every token the bridge creates,
    /// including a `.retryable` re-arm — not just the ones from an explicit
    /// ``registerApplied(_:)`` call) so ``invalidate(commit:)`` can remove exactly one record's
    /// action.
    private var tokens: [String: UndoBridge<Record>.Token] = [:]

    /// The in-flight reverse-apply spawned by the most recent ⌘Z. Exposed for tests, which
    /// `await` it to observe the re-register-on-retryable behavior deterministically.
    var pendingPerform: Task<Void, Never>? { bridge.pendingPerform }

    /// The ``Performer`` is fixed at construction; ``undoManager`` is deliberately *not* a
    /// parameter — SwiftUI supplies it later (and can change it per focused window) via
    /// `@Environment(\.undoManager)`, so it stays a settable property instead.
    public init(perform: @escaping Performer) {
        bridge = UndoBridge { record in
            switch await perform(record) {
            case .undone: return .succeeded
            case .retryable: return .retry
            case .stale: return .rejected
            }
        }
    }

    /// Registers an applied edit on the undo stack. Call at apply time, right after the edit
    /// row is recorded. No-op when no ``undoManager`` is attached.
    public func registerApplied(_ record: Record) {
        bridge.register(
            record, redo: nil, actionName: Self.actionName(for: record),
            onRegister: { [weak self] op, token in self?.tokens[op.commit] = token },
            onFire: { [weak self] fired in self?.tokens[fired.commit] = nil }
        )
    }

    /// Removes a still-pending record from the undo stack — call after an edit was undone via
    /// another path (e.g. the chat row's Undo button) so ⌘Z skips it. No-op for unknown or
    /// already-fired records.
    public func invalidate(commit: String) {
        guard let token = tokens.removeValue(forKey: commit) else { return }
        bridge.remove(token)
    }

    /// Drops every pending record — call when the transcript backing the records is cleared
    /// wholesale (reset conversation), so ⌘Z can't fire actions whose rows no longer exist.
    public func invalidateAll() {
        for token in tokens.values {
            bridge.remove(token)
        }
        tokens.removeAll()
    }

    /// Menu action name for a record: "Edit <filename>" → the menu shows "Undo Edit <filename>".
    public static func actionName(for record: Record) -> String {
        let filename = record.file.split(separator: "/").last.map(String.init) ?? record.file
        return "Edit \(filename)"
    }
}
#endif
