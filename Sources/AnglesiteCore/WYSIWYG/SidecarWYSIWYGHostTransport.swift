import Foundation

/// Real `WYSIWYGHostTransport` conformance, backed by the sidecar's `get_page_model` tool and
/// its `apply_edit` block-editor ops. Successor to `StubWYSIWYGHostTransport` for production use
/// (#1222) — see this feature's plan doc for the two-round-trip design (`sendOp` applies, then
/// re-fetches the model; the sidecar doesn't piggyback a fresh page model onto these ops' reply).
public actor SidecarWYSIWYGHostTransport: WYSIWYGServerInvertibleTransport {
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
        await sendOpReportingServerInverse(envelope).result
    }

    public func sendOpReportingServerInverse(_ envelope: OpEnvelope) async -> (result: OpResult, serverInverse: WireInverse?) {
        let message = WYSIWYGOpTranslator.translate(
            envelope.op, requestId: envelope.id, path: path, baseVersion: envelope.targetVersion, rootId: rootId)
        var insertBlockContent: BlockNodeContent?
        if case .insertBlock(_, _, _, _, let block) = envelope.op {
            insertBlockContent = block
        }
        return await applyMessageAndAdapt(message, insertBlockContent: insertBlockContent, requestId: envelope.id)
    }

    public func applyServerInverse(_ inverse: WireInverse, requestId: String) async -> (result: OpResult, serverInverse: WireInverse?) {
        // A server-computed inverse for `deleteBlock` reinstates via `NodeSpec.raw` — full,
        // already-serialized markup — so unlike a fresh `insertBlock` translated from an `Op`,
        // replaying one never needs the props/richText follow-up dance below.
        let message = EditMessage(id: requestId, path: path, selector: nil, op: inverse.op, component: inverse.component, value: nil)
        return await applyMessageAndAdapt(message, insertBlockContent: nil, requestId: requestId)
    }

    /// Shared apply+re-fetch+adapt core for `sendOpReportingServerInverse`/`applyServerInverse` —
    /// factors out what used to be `sendOp(_:)`'s whole body, adding the reply's own
    /// `inverseOp`/`inverseComponent` decode (Task 4) into a `WireInverse` on success.
    /// `insertBlockContent` is non-nil only for a translated `Op.insertBlock` (never for a
    /// replayed `WireInverse` — see `applyServerInverse`'s doc comment above).
    private func applyMessageAndAdapt(
        _ message: EditMessage, insertBlockContent: BlockNodeContent?, requestId: String
    ) async -> (result: OpResult, serverInverse: WireInverse?) {
        let reply = await editRouter.apply(message)
        switch reply.status {
        case .applied:
            if let insertBlockContent {
                if let rejection = await applyInsertFollowUp(insertBlockContent, insertReply: reply, requestId: requestId) {
                    return (rejection, nil)
                }
            }
            do {
                let fresh = try await pageModelClient.fetch(path: path)
                rootId = fresh.tree.id
                let serverInverse: WireInverse?
                if let inverseOp = reply.inverseOp, let inverseComponent = reply.inverseComponent {
                    serverInverse = WireInverse(op: inverseOp, component: inverseComponent)
                } else {
                    serverInverse = nil
                }
                return (.applied(model: PageModelBlockAdapter.adapt(fresh)), serverInverse)
            } catch {
                // The write landed but the re-fetch failed — surface as a host error with no
                // fresh model rather than silently claiming success without a model to show.
                return (.rejected(reason: .hostError, message: "edit applied but re-fetch failed: \(error)", freshModel: nil), nil)
            }
        case .failed:
            let reason: OpRejectionReason = (reply.reason == "stale") ? .versionMismatch : .hostError
            var freshModel: BlockModel?
            if reason == .versionMismatch, let fresh = try? await pageModelClient.fetch(path: path) {
                rootId = fresh.tree.id
                freshModel = PageModelBlockAdapter.adapt(fresh)
            }
            return (.rejected(reason: reason, message: reply.message, freshModel: freshModel), nil)
        case .ambiguous, .preview:
            // Neither status is reachable here: `EditMessage`'s `dryRun` defaults false (no
            // preview requested) and these ops don't use `selector`-based matching (no ambiguity
            // path). Treat defensively as a host error rather than force-unwrapping an assumption.
            return (.rejected(reason: .hostError, message: "unexpected reply status: \(reply.status)", freshModel: nil), nil)
        }
    }

    /// The sidecar's `insertBlock`/`insert-node` wire schema has NO attributes field, and no
    /// text-content field either (`apply-edit-schema.mjs`'s `componentEditSchema`, confirmed
    /// against `server/component-structure-edit.mjs`'s `applyInsertNode`) — so a `.insertBlock` op
    /// whose `block.props` and/or `block.richText` is non-empty can't carry that content in the
    /// insert call itself. This issues one `setAttr` follow-up per prop, then (if `richText` is
    /// non-empty) one `editText` follow-up, all addressed at the newly-inserted node's REAL
    /// (server-assigned) id — learned from `insertReply.inverseNodeId`, a narrow,
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
    /// information to address the new node, a `setAttr` call failed, or the `editText` call
    /// failed. Returns `nil` when every follow-up landed (or none were needed), so the caller
    /// proceeds to its normal re-fetch+adapt path.
    ///
    /// `props` is a `[String: PropValue]` dictionary — iteration order isn't guaranteed, but each
    /// `setAttr` call targets a distinct attribute name independently, so that's harmless here.
    ///
    /// `.null`-valued props (`PropValue.null` — `PageModelBlockAdapter` maps every valueless HTML
    /// attribute, e.g. `disabled`/`required`/`open`/`checked`, to this case) are skipped entirely
    /// rather than sent as a `setAttr`: `WYSIWYGOpTranslator.stringValue(.null)` is `nil`, and
    /// `setAttr`'s `value: nil` means "remove this attribute" (its own doc comment) — but the
    /// node was JUST inserted with no attributes at all, so the sidecar refuses that as
    /// `no-match` (nothing to remove), which would otherwise fail the whole insert. There is no
    /// wire-level way to *add* a valueless/boolean attribute through `insertBlock` or `setAttr`
    /// (`setAttr`'s `value: nil` only ever means "remove," never "add present-with-no-value"), so
    /// this is the same lossy-but-non-destructive tradeoff `stringValue`'s own doc comment already
    /// applies to `.object`/`.array` — the attribute is silently dropped for this op family, not
    /// destructively mishandled. (`stringValue` itself must keep mapping `.null` → `nil` — it's
    /// shared with `WYSIWYGOpTranslator.translate`'s `setProp` case, where `.null` legitimately
    /// means "remove this EXISTING attribute" and has to keep working; the skip belongs here, at
    /// the insert-follow-up call site, not inside `stringValue`.)
    private func applyInsertFollowUp(_ block: BlockNodeContent, insertReply: EditReply, requestId: String) async -> OpResult? {
        // Drop `.null` props BEFORE the nodeId/version guard below — a block whose props are all
        // `.null` (e.g. duplicating `<button disabled>`, which carries only the one boolean
        // attribute) needs no follow-up `setAttr` calls at all, so it must not fail just because
        // the insert reply happened not to carry an `inverseNodeId`/`postWriteVersion` that
        // nothing here would actually use.
        let attributeProps = block.props.filter { _, value in
            if case .null = value { return false }
            return true
        }
        let richText = block.richText ?? []
        guard !attributeProps.isEmpty || !richText.isEmpty else { return nil }
        guard let nodeId = insertReply.inverseNodeId, let initialVersion = insertReply.postWriteVersion else {
            return .rejected(
                reason: .hostError,
                message: "The block was inserted, but its content could not be finalized — the "
                    + "preview server's reply didn't include enough information to address the "
                    + "new block.",
                freshModel: nil
            )
        }
        var baseVersion = initialVersion
        for (index, (name, value)) in attributeProps.enumerated() {
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
        if !richText.isEmpty {
            let textMessage = ComponentStructureEditBuilder.editText(
                id: "\(requestId)-text", path: path, baseVersion: baseVersion, textNodeId: nodeId, runs: richText)
            let textReply = await editRouter.apply(textMessage)
            guard textReply.status == .applied else {
                return .rejected(
                    reason: .hostError,
                    message: "The block was inserted, but setting its text failed: "
                        + "\(textReply.message ?? "unknown error").",
                    freshModel: nil
                )
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
