// Sources/AnglesiteIOS/PostComposerModel.swift
import Foundation
import SwiftUI
import AnglesiteCore

/// Drives the iOS composer (#869): a typed, registry-driven form over one post, written through
/// `MicropubClient` — the same write path the Mac's CMS-mode save uses, so Mac and phone edits
/// can't diverge (design §6).
///
/// The publish model is the design's real-time-first contract: Save/Publish attempts an
/// **immediate foreground request**. Only on a retryable failure (5xx, unreachable/offline) does
/// the composition drop to a locally-queued draft with an explicit ``Phase/waitingForNetwork``
/// state; composing itself never needs the network. A 401/403 surfaces as
/// ``Phase/authRequired`` — an IndieAuth matter for the onboarding flow (#868), not a network
/// failure (§7). Concurrent edits are compare-and-swap: before updating an existing post the
/// model re-fetches `q=source` and compares against the baseline it loaded from — a changed
/// server copy becomes ``Phase/conflict(_:)`` for the owner to resolve, phrased by the screen in
/// terms of their post, never a merge (§6).
@MainActor
@Observable
public final class PostComposerModel {
    /// Where the composition stands. One phase at a time — the screen renders exactly this.
    public enum Phase: Equatable {
        /// Composing; no request in flight.
        case editing
        /// A foreground send (save or publish) is in flight.
        case sending
        /// The last send failed retryably (offline/5xx); the draft is queued locally and
        /// ``retry()`` re-attempts it. The design's explicit "waiting for network" state — the
        /// screen must not promise a delivery time (§ open questions).
        case waitingForNetwork
        /// The server copy changed since this composition's baseline; carries the server's
        /// current post. Resolve with ``keepMine()`` or ``takeTheirs()``.
        case conflict(MicropubPost)
        /// The token was rejected (401/403) — route to IndieAuth re-auth (#868), distinct from
        /// any network failure.
        case authRequired
        /// A terminal failure (a 4xx the same payload can't fix, or a malformed response);
        /// carries a short description.
        case failed(String)
        /// The post is saved server-side as a draft; carries its canonical URL.
        case savedDraft(URL)
        /// `post-status` flipped to published — the Worker-side bake is running. The screen shows
        /// "Published — site rebuilding" and never fakes a live preview (§6).
        case publishedRebuilding(URL)
    }

    /// The content type being composed.
    public let descriptor: ContentTypeDescriptor
    /// The site this composition belongs to (keys the draft store).
    public let siteID: UUID
    /// The form's field values — the single source the bindings below read and write.
    public var values: TypedContentEditor.Values
    /// The composition's audience tier (#1566) — `public` by default. Stamped into every
    /// create/update alongside `post-status`; read back from an opened post's stored properties.
    public var visibility: MicropubPostVisibility = .public
    /// The composition's phase — see ``Phase``.
    public private(set) var phase: Phase = .editing
    /// The post's canonical URL: `nil` until a create succeeds, then stable across updates.
    public private(set) var postURL: URL?

    /// The `q=source` snapshot this composition edits against — the compare-and-swap baseline.
    /// `nil` for a new post (nothing to conflict with).
    private var baseline: MicropubPost?
    /// The status a queued (failed-retryable) send should stamp when retried.
    private var queuedStatus: MicropubPostStatus?
    private let client: MicropubClient
    private let draftStore: ComposerDraftStore
    /// In-progress number text per field, so a mid-edit draft like "3." never clobbers a valid
    /// stored number — mirrors `TypedEntryEditorModel.numberDrafts` on the Mac.
    private var numberDrafts: [String: String] = [:]

    /// Starts a new composition of `descriptor` for `siteID`, empty-by-default values.
    ///
    /// - Parameters:
    ///   - descriptor: The content type to compose.
    ///   - siteID: The site's stable UUID (draft-store key).
    ///   - client: The site's Micropub client (from the ``MicropubSession``).
    ///   - draftStore: Where queued/restored drafts persist; tests inject a scratch directory.
    ///   - restoringDraft: A previously persisted draft to restore (same site + type), e.g.
    ///     after an interrupted session.
    public init(
        descriptor: ContentTypeDescriptor,
        siteID: UUID,
        client: MicropubClient,
        draftStore: ComposerDraftStore = ComposerDraftStore(),
        restoringDraft: ComposerDraft? = nil
    ) {
        self.descriptor = descriptor
        self.siteID = siteID
        self.client = client
        self.draftStore = draftStore
        var values = TypedContentEditor.Values()
        for field in descriptor.fields {
            values[field.name] = TypedContentEditor.defaultValue(for: field.kind)
        }
        var restoredURL: URL?
        var restoredStatus: MicropubPostStatus?
        var restoredBaseline: MicropubPost?
        var restoredVisibility: MicropubPostVisibility?
        if let restoringDraft, restoringDraft.typeID == descriptor.id {
            let restored = restoringDraft.editorValues
            for field in descriptor.fields {
                if let value = restored[field.name] { values[field.name] = value }
            }
            restoredURL = restoringDraft.postURL
            restoredBaseline = restoringDraft.baseline
            restoredStatus = restoringDraft.queuedStatus
                .flatMap(MicropubPostStatus.init(rawValue:))
            restoredVisibility = restoringDraft.visibility.flatMap(MicropubPostVisibility.init(rawValue:))
        }
        self.values = values
        self.postURL = restoredURL
        self.baseline = restoredBaseline
        self.queuedStatus = restoredStatus
        if let restoredVisibility { self.visibility = restoredVisibility }
        if restoredStatus != nil { self.phase = .waitingForNetwork }
    }

    /// Opens an existing post for editing: fetches its `q=source` baseline and decodes it into
    /// form values through the same mapping the Mac's sync bridge reads with
    /// (`MicropubContentSync.values`).
    ///
    /// - Parameters:
    ///   - url: The post's canonical URL.
    ///   - descriptor: Its content type (resolved by the post list from the URL's collection).
    ///   - siteID: The site's stable UUID.
    ///   - client: The site's Micropub client.
    ///   - draftStore: Where queued/restored drafts persist.
    /// - Returns: A composer editing the post.
    /// - Throws: `MicropubError` when the source fetch fails; the caller surfaces it in the
    ///   list UI rather than opening a broken composer.
    public static func openExisting(
        url: URL,
        descriptor: ContentTypeDescriptor,
        siteID: UUID,
        client: MicropubClient,
        draftStore: ComposerDraftStore = ComposerDraftStore()
    ) async throws -> PostComposerModel {
        let post = try await client.source(url: url)
        let model = PostComposerModel(
            descriptor: descriptor, siteID: siteID, client: client, draftStore: draftStore)
        guard model.adopt(post: post, url: url) else {
            throw MicropubError.decodingFailed(
                "post at \(url.absoluteString) doesn't decode into \(descriptor.id)'s fields")
        }
        return model
    }

    /// Replaces the composition's values and baseline with `post` — the open-existing path and
    /// ``takeTheirs()`` both land here. `false` when the post doesn't decode into this
    /// descriptor's fields (a required field with no resolvable value): adopting it anyway
    /// would blank the form over a real baseline, and the next save's cleared-property delete
    /// pass would then wipe the post's actual content server-side (#1370 review) — so the
    /// caller must surface an error instead.
    private func adopt(post: MicropubPost, url: URL) -> Bool {
        let slug = MicropubContentSync.collectionAndSlug(from: url.absoluteString)?.slug ?? ""
        guard let decoded = MicropubContentSync.values(
            for: descriptor,
            properties: post.properties,
            updatedAt: Int(Date.now.timeIntervalSince1970),
            slug: slug
        ) else { return false }
        var values = TypedContentEditor.Values()
        for field in descriptor.fields {
            values[field.name] = decoded[field.name]
                ?? TypedContentEditor.defaultValue(for: field.kind)
        }
        self.values = values
        self.visibility = post.visibility
        self.numberDrafts = [:]
        self.postURL = url
        self.baseline = post
        self.phase = .editing
        return true
    }

    // MARK: - Send path

    /// Saves the composition server-side as a draft (creates or updates with
    /// `post-status: draft`). Foreground-first; see ``Phase`` for the failure routing.
    public func saveDraft() async {
        await send(status: .draft)
    }

    /// Publishes the composition (creates or updates with `post-status: published`), which
    /// triggers the Worker-side bake — on success the phase is ``Phase/publishedRebuilding(_:)``.
    public func publish() async {
        await send(status: .published)
    }

    /// Re-attempts a queued send from ``Phase/waitingForNetwork`` — wired to the screen's Retry
    /// button and its network-restored trigger.
    public func retry() async {
        guard case .waitingForNetwork = phase, let status = queuedStatus else { return }
        await send(status: status)
    }

    /// Proceeds with this composition's values despite the conflict — the owner chose their
    /// version. The server's current copy becomes the new baseline first, so the retried send's
    /// own compare-and-swap passes unless a *further* edit lands in between.
    public func keepMine() async {
        guard case .conflict(let theirs) = phase, postURL != nil else { return }
        baseline = theirs
        phase = .editing
        await send(status: queuedStatus ?? .draft)
    }

    /// Discards this composition's changes in favor of the server's current copy — the owner
    /// chose the other device's version. Back to editing with the fresh values; if the site's
    /// copy doesn't decode into this type's fields, the composition fails visibly instead of
    /// silently blanking the form over a live baseline.
    public func takeTheirs() {
        guard case .conflict(let theirs) = phase, let url = postURL else { return }
        guard adopt(post: theirs, url: url) else {
            phase = .failed("The site's copy of this post couldn't be read.")
            return
        }
        clearQueuedDraft()
    }

    /// Acknowledges a terminal state (``Phase/failed(_:)``, ``Phase/savedDraft(_:)``,
    /// ``Phase/publishedRebuilding(_:)``) and returns to editing.
    public func resumeEditing() {
        phase = .editing
    }

    private func send(status: MicropubPostStatus) async {
        phase = .sending
        queuedStatus = status
        do {
            if let url = postURL {
                // Compare-and-swap: an existing post is only updated if the server still holds
                // the copy this composition was loaded from (§6). New posts skip this — there is
                // nothing to conflict with. The compare ignores server-injected bookkeeping
                // (`url`) and stripped-on-store commands (`mp-*`) so only real content edits
                // read as conflicts.
                let current = try await client.source(url: url)
                if let baseline, Self.casComparable(current) != Self.casComparable(baseline) {
                    phase = .conflict(current)
                    return
                }
                try await update(url: url, status: status)
            } else {
                let url = try await create(status: status)
                postURL = url
            }
            clearQueuedDraft()
            if let url = postURL {
                phase = status == .published ? .publishedRebuilding(url) : .savedDraft(url)
            } else {
                phase = .editing
            }
        } catch let error as MicropubError {
            if error.requiresReauthorization {
                phase = .authRequired
            } else if error.isRetryable {
                persistQueuedDraft(status: status)
                phase = .waitingForNetwork
            } else {
                // Terminal: the same payload can never succeed, so a draft queued by an
                // earlier retryable failure must not resurrect it as "waiting for network"
                // on the next launch (#1370 review).
                clearQueuedDraft()
                phase = .failed(Self.describe(error))
            }
        } catch {
            clearQueuedDraft()
            phase = .failed(error.localizedDescription)
        }
    }

    /// A post's properties with server-side bookkeeping removed, for the compare-and-swap
    /// equality: `url` (injected by the server, never a content edit) and `mp-*` commands
    /// (stripped before storing, so a locally-constructed baseline may carry them while a
    /// `q=source` read never does).
    private static func casComparable(_ post: MicropubPost) -> MicropubPost {
        var normalized = post
        normalized.properties = post.properties.filter { key, _ in
            key != "url" && !key.hasPrefix("mp-")
        }
        return normalized
    }

    private func create(status: MicropubPostStatus) async throws -> URL {
        var properties = MicropubComposerProjection.properties(
            for: descriptor, values: values, status: status, visibility: visibility)
        // `mp-slug` is create-only: derive it from the title field the same way the Mac's
        // file-based create does, so both paths land the same slug for the same title.
        let title = descriptor.titleField.flatMap { field -> String? in
            if case .text(let s)? = values[field.name] { return s }
            return nil
        }
        if let slug = MicropubClient.deriveSlug(title: title) {
            properties["mp-slug"] = [.string(slug)]
        }
        let post = MicropubPost(properties: properties)
        let url = try await client.create(post)
        // The new CAS baseline is what was just stored, constructed locally rather than
        // re-fetched: a failed `try?` refetch used to null the baseline and silently disable
        // both the conflict check and cleared-property deletes for the rest of the session
        // (#1370 review). `casComparable` strips the create-only `mp-*` commands on compare.
        baseline = post
        return url
    }

    private func update(url: URL, status: MicropubPostStatus) async throws {
        // Visibility only travels on an update when the owner actually changed the picker. The
        // Worker's tier vocabulary is wider than `MicropubPostVisibility`, and
        // `MicropubPost.visibility` reads anything it doesn't recognize (`unlisted`, `private`)
        // as `public` — so re-stamping the value this composition merely *read back* would
        // silently republish a restricted post to the world. An unchanged picker sends nothing
        // and leaves the server's real tier alone.
        let baselineVisibility = baseline?.visibility ?? .public
        let replace = MicropubComposerProjection.properties(
            for: descriptor, values: values, status: status,
            visibility: visibility != baselineVisibility ? visibility : nil)
        // A mapped property present on the baseline but absent from this send was cleared in
        // the form — delete it server-side. Unmapped properties (another client's vocabulary)
        // are never touched.
        let cleared = MicropubComposerProjection.mappedProperties(for: descriptor).filter {
            baseline?.properties[$0] != nil && replace[$0] == nil
        }
        try await client.update(
            url: url,
            replace: replace,
            delete: cleared.isEmpty ? nil : .properties(cleared)
        )
        // New baseline = the update applied to the old one, constructed locally (same
        // no-refetch reasoning as `create`): replaced properties overwrite, cleared ones go,
        // untouched ones — including other clients' vocabulary — carry over unchanged.
        var properties = baseline?.properties ?? [:]
        for name in cleared { properties[name] = nil }
        for (name, values) in replace { properties[name] = values }
        baseline = MicropubPost(type: baseline?.type ?? ["h-entry"], properties: properties)
    }

    // MARK: - Media

    /// Uploads one picked image through the media endpoint, guarded by ``MediaUploadGuard``
    /// first (§7's pre-upload size/format check — error handling, not compression UX).
    ///
    /// - Parameters:
    ///   - data: The image bytes (the picker layer transcodes Photos exports to JPEG first).
    ///   - filename: The upload's filename.
    ///   - mimeType: The image's MIME type.
    /// - Returns: The stored media's URL, ready to set as an image field's value.
    /// - Throws: ``MediaUploadError`` wrapping either the local rejection or the transport
    ///   failure — media failures stay inline in the form; they never change ``phase``.
    public func uploadImage(data: Data, filename: String, mimeType: String) async throws -> URL {
        if let rejection = MediaUploadGuard.rejection(for: data, mimeType: mimeType) {
            throw MediaUploadError.rejected(rejection)
        }
        do {
            return try await client.uploadMedia(data, filename: filename, mimeType: mimeType)
        } catch let error as MicropubError {
            throw MediaUploadError.transport(error)
        }
    }

    /// Why ``uploadImage(data:filename:mimeType:)`` failed — local guard or transport.
    public enum MediaUploadError: Error, Equatable {
        /// Rejected before any request — see ``MediaUploadGuard/Rejection``.
        case rejected(MediaUploadGuard.Rejection)
        /// The upload itself failed.
        case transport(MicropubError)
    }

    // MARK: - Draft persistence

    /// Persists the current values as the site's in-progress draft — the screen calls this on
    /// backgrounding so an interrupted session restores (§3).
    public func persistDraft() {
        persistQueuedDraft(status: nil)
    }

    private func persistQueuedDraft(status: MicropubPostStatus?) {
        let draft = ComposerDraft(
            siteID: siteID, typeID: descriptor.id, postURL: postURL,
            editorValues: values, fieldNames: descriptor.fields.map(\.name),
            queuedStatus: status?.rawValue,
            visibility: visibility.rawValue,
            // The CAS baseline persists with a queued update so restoring the draft restores
            // the conflict guard too, not just the values (#1370 review).
            baseline: postURL != nil ? baseline : nil)
        try? draftStore.save(draft)
    }

    private func clearQueuedDraft() {
        queuedStatus = nil
        // Both identities this composition may have persisted under: its pre-create
        // "new:<type>" file and, once created, its "post:<url>" file — a create transitions
        // from the first to the second mid-session.
        draftStore.clear(forSite: siteID, postURL: nil, typeID: descriptor.id)
        if let postURL {
            draftStore.clear(forSite: siteID, postURL: postURL, typeID: descriptor.id)
        }
    }

    private static func describe(_ error: MicropubError) -> String {
        switch error {
        case .requestFailed(let status, _):
            return "The site declined the request (HTTP \(status))."
        case .decodingFailed:
            return "The site's response wasn't understood."
        case .mediaEndpointNotConfigured:
            return "This site has no media endpoint configured."
        case .dpopUnavailable:
            return "Secure signing is unavailable on this device."
        case .unauthorized, .serverError, .unreachable:
            // Routed to dedicated phases before reaching here; text kept for completeness.
            return "The request failed."
        }
    }

    // MARK: - Form bindings (mirroring TypedEntryEditorModel's surface on the Mac)

    /// Two-way text binding for string-like fields (and the markdown body).
    public func textBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { [weak self] in
                if case .text(let s)? = self?.values[name] { return s }
                return ""
            },
            set: { [weak self] in self?.values[name] = .text($0) }
        )
    }

    /// Two-way toggle binding for bool fields.
    public func boolBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { [weak self] in
                if case .flag(let b)? = self?.values[name] { return b }
                return false
            },
            set: { [weak self] in self?.values[name] = .flag($0) }
        )
    }

    /// Two-way date binding for date/datetime fields (an unset date reads as now).
    public func dateBinding(_ name: String) -> Binding<Date> {
        Binding(
            get: { [weak self] in
                if case .date(let d?)? = self?.values[name] { return d }
                return Date()
            },
            set: { [weak self] in self?.values[name] = .date($0) }
        )
    }

    /// Two-way text binding for number fields, buffering unparseable mid-edit drafts so "3."
    /// on its way to "3.5" never clobbers a stored value.
    public func numberBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { [weak self] in
                guard let self else { return "" }
                if let draft = self.numberDrafts[name] { return draft }
                if case .number(let n?)? = self.values[name] {
                    return ComposerNumberFormat.display(n)
                }
                return ""
            },
            set: { [weak self] raw in
                guard let self else { return }
                self.numberDrafts[name] = raw
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    self.values[name] = .number(nil)
                } else if let parsed = Double(trimmed) {
                    self.values[name] = .number(parsed)
                }
            }
        )
    }

    /// Two-way binding for string-array/image-array fields.
    public func listBinding(_ name: String) -> Binding<[String]> {
        Binding(
            get: { [weak self] in
                if case .list(let a)? = self?.values[name] { return a }
                return []
            },
            set: { [weak self] in self?.values[name] = .list($0) }
        )
    }

    /// Two-way binding for object-array fields' record rows.
    public func recordsBinding(_ name: String) -> Binding<[[String: TypedContentEditor.FieldValue]]> {
        Binding(
            get: { [weak self] in
                if case .records(let r)? = self?.values[name] { return r }
                return []
            },
            set: { [weak self] in self?.values[name] = .records($0) }
        )
    }

}

/// The composer's one number-display rule, shared by the top-level form bindings and the
/// nested record editor so the two can't drift (#1370 review): integral values render without
/// a trailing ".0" (the magnitude guard avoids the `Int(_:)` overflow trap), mirroring the Mac
/// form's convention.
public enum ComposerNumberFormat {
    /// The display string for a stored number.
    public static func display(_ n: Double) -> String {
        if n == n.rounded(), abs(n) < 1e15 { return String(Int(n)) }
        return String(n)
    }
}
