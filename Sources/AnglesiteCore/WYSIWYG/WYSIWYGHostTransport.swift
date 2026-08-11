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
