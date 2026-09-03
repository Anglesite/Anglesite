import Foundation

/// Read/write seam from a chat `Tool` (which lives in `AnglesiteCore`) into the live WYSIWYG
/// canvas (which lives in `AnglesiteApp` — the wrong dependency direction for a direct reference,
/// confirmed by inspection: `AnglesiteCore` cannot import `AnglesiteApp`). `WYSIWYGCanvasController`
/// conforms to this in `AnglesiteApp` (Task 8); `AnglesiteCore` only ever sees it as `any
/// WYSIWYGBlockTextAccess`, exactly the pattern `IntentEditBridge` already uses for the legacy
/// overlay editor's own cross-module seam.
public protocol WYSIWYGBlockTextAccess: Sendable {
    /// The block's current plain text, or `nil` when no block with this id exists (e.g. it was
    /// deleted, or the canvas isn't mounted at all).
    func blockText(_ id: String) async -> String?
    /// Submits `newText` as a full plain-text replacement for the block's rich text (an `editText`
    /// op — see plan Global Constraints on formatting loss). Returns whether the op applied.
    func submitRewrite(blockId: String, newText: String) async -> Bool
}
