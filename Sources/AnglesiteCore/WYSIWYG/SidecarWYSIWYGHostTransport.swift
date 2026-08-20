import Foundation

/// Real `WYSIWYGHostTransport` conformance, backed by the sidecar's `get_page_model` tool and
/// its `apply_edit` block-editor ops. Successor to `StubWYSIWYGHostTransport` for production use
/// (#1222) — see this feature's plan doc for the two-round-trip design (`sendOp` applies, then
/// re-fetches the model; the sidecar doesn't piggyback a fresh page model onto these ops' reply).
public actor SidecarWYSIWYGHostTransport: WYSIWYGHostTransport {
    private let path: String
    private let pageModelClient: PageModelClient
    private let editRouter: any EditRouter
    private var listeners: [UUID: @Sendable (BlockModel) -> Void] = [:]

    public init(path: String, pageModelClient: PageModelClient, editRouter: any EditRouter) {
        self.path = path
        self.pageModelClient = pageModelClient
        self.editRouter = editRouter
    }

    public func sendOp(_ envelope: OpEnvelope) async -> OpResult {
        let message = WYSIWYGOpTranslator.translate(envelope.op, requestId: envelope.id, path: path, baseVersion: envelope.targetVersion)
        let reply = await editRouter.apply(message)
        switch reply.status {
        case .applied:
            do {
                let fresh = try await pageModelClient.fetch(path: path)
                return .applied(model: PageModelBlockAdapter.adapt(fresh))
            } catch {
                // The write landed but the re-fetch failed — surface as a host error with no
                // fresh model rather than silently claiming success without a model to show.
                return .rejected(reason: .hostError, message: "edit applied but re-fetch failed: \(error)", freshModel: nil)
            }
        case .failed:
            let reason: OpRejectionReason = (reply.reason == "stale") ? .versionMismatch : .hostError
            var freshModel: BlockModel?
            if reason == .versionMismatch, let fresh = try? await pageModelClient.fetch(path: path) {
                freshModel = PageModelBlockAdapter.adapt(fresh)
            }
            return .rejected(reason: reason, message: reply.message, freshModel: freshModel)
        case .ambiguous, .preview:
            // Neither status is reachable here: `EditMessage`'s `dryRun` defaults false (no
            // preview requested) and these ops don't use `selector`-based matching (no ambiguity
            // path). Treat defensively as a host error rather than force-unwrapping an assumption.
            return .rejected(reason: .hostError, message: "unexpected reply status: \(reply.status)", freshModel: nil)
        }
    }

    public func onModelUpdate(_ listener: @escaping @Sendable (BlockModel) -> Void) async -> () -> Void {
        // No live external-edit push exists yet — mirrors StubWYSIWYGHostTransport's own
        // not-yet-wired listener registry (same TODO, same reasoning: keeps protocol parity for
        // when a real push mechanism lands, without inventing one here).
        let token = UUID()
        listeners[token] = listener
        return { [weak self] in
            guard let self else { return }
            Task { await self.removeListener(token) }
        }
    }

    private func removeListener(_ token: UUID) {
        listeners.removeValue(forKey: token)
    }
}
