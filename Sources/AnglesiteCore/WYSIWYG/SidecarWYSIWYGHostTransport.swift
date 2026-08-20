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
    /// The current model's real root-fragment id (`PageModel.tree.id`, e.g. `"n0"`) —
    /// substituted for the app-side `rootParentID` sentinel when translating an `Op` (final-review
    /// Finding 1). Seeded at construction from whatever `get_page_model` fetch produced the
    /// caller's initial `BlockModel`, and refreshed every time this transport re-fetches the
    /// model itself (`sendOp`'s `.applied`/stale-refresh paths) so it never goes stale even
    /// though the sidecar's root id is, in practice, deterministically stable.
    private var rootId: BlockId

    public init(path: String, pageModelClient: PageModelClient, editRouter: any EditRouter, rootId: BlockId) {
        self.path = path
        self.pageModelClient = pageModelClient
        self.editRouter = editRouter
        self.rootId = rootId
    }

    public func sendOp(_ envelope: OpEnvelope) async -> OpResult {
        let message = WYSIWYGOpTranslator.translate(
            envelope.op, requestId: envelope.id, path: path, baseVersion: envelope.targetVersion, rootId: rootId)
        let reply = await editRouter.apply(message)
        switch reply.status {
        case .applied:
            if case .insertBlock(_, _, _, _, let block) = envelope.op, !block.props.isEmpty {
                if let rejection = await applyPropsFollowUp(block.props, insertReply: reply, requestId: envelope.id) {
                    return rejection
                }
            }
            do {
                let fresh = try await pageModelClient.fetch(path: path)
                rootId = fresh.tree.id
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
                rootId = fresh.tree.id
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

    /// The sidecar's `insertBlock`/`insert-node` wire schema has NO attributes field at all
    /// (`apply-edit-schema.mjs`'s `componentEditSchema`, confirmed against
    /// `server/component-structure-edit.mjs`'s `applyInsertNode`) — so a `.insertBlock` op whose
    /// `block.props` is non-empty can't carry those attributes in the insert call itself. This
    /// issues one `setAttr` follow-up per prop instead, addressed at the newly-inserted node's
    /// REAL (server-assigned) id — learned from `insertReply.inverseNodeId`, a narrow,
    /// explicitly-scoped decode of the insert reply's `inverse.component.nodeId` (see
    /// `EditReply`'s doc comments — this is NOT an adoption of the sidecar's general
    /// inverse-for-undo mechanism, which stays out of scope per the plan doc's design decision
    /// 1). `baseVersion` chains forward from each successive reply's own `postWriteVersion`
    /// (`inverse.component.baseVersion`, stamped by the sidecar's dispatcher with the file's
    /// POST-write hash) so each follow-up targets the file's actual current version rather than
    /// the now-stale version the insert itself was sent with.
    ///
    /// Returns a `.rejected` result — honest about exactly what did and didn't land — the moment
    /// anything about the follow-up can't proceed: the insert reply didn't carry enough
    /// information to address the new node, or a `setAttr` call itself failed. Returns `nil` when
    /// every prop's `setAttr` landed, so the caller proceeds to its normal re-fetch+adapt path.
    ///
    /// `props` is a `[String: PropValue]` dictionary — iteration order isn't guaranteed, but each
    /// `setAttr` call targets a distinct attribute name independently, so that's harmless here.
    private func applyPropsFollowUp(_ props: [String: PropValue], insertReply: EditReply, requestId: String) async -> OpResult? {
        guard let nodeId = insertReply.inverseNodeId, let initialVersion = insertReply.postWriteVersion else {
            return .rejected(
                reason: .hostError,
                message: "The block was inserted, but its attributes could not be set — the "
                    + "preview server's reply didn't include enough information to address the "
                    + "new block.",
                freshModel: nil
            )
        }
        var baseVersion = initialVersion
        for (index, (name, value)) in props.enumerated() {
            let setMessage = ComponentStructureEditBuilder.setAttr(
                id: "\(requestId)-attr-\(index)", path: path, baseVersion: baseVersion,
                nodeId: nodeId, name: name, value: WYSIWYGOpTranslator.stringValue(value))
            let setReply = await editRouter.apply(setMessage)
            guard setReply.status == .applied else {
                return .rejected(
                    reason: .hostError,
                    message: "The block was inserted, but setting its \"\(name)\" attribute "
                        + "failed: \(setReply.message ?? "unknown error"). The block now exists "
                        + "with only the attributes applied before this failure.",
                    freshModel: nil
                )
            }
            if let nextVersion = setReply.postWriteVersion {
                baseVersion = nextVersion
            }
        }
        return nil
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
