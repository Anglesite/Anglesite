// `ChatModel` is target-agnostic: it depends on the `ConversationalAssistant` protocol, so it
// compiles in the App Store target and in package tests. Production constructs it with a
// `FoundationModelAssistant` backend; tests and previews inject lightweight fakes.
import Foundation
import Observation
import AnglesiteBridge
import AnglesiteCore

/// SwiftUI-facing wrapper around ``ConversationalAssistant`` for one site. Owns the
/// assistant, accumulates streamed events into typed `Message` values, persists every
/// user/assistant/tool entry to the package's `Config/chat-history.jsonl`, and exposes the
/// streaming + cancel surface that `ChatView` binds to.
///
/// Threading: this model is `@MainActor` so all SwiftUI bindings stay on the main actor.
/// The assistant produces ``AssistantEvent`` values on its own executor; we iterate the
/// `AsyncStream` on the main actor (the iteration hops between executors at each `await`).
///
/// Persistence rule: every terminal piece of content gets persisted at the moment it's
/// considered "done." User prompts persist on send; assistant text persists when the *next*
/// event arrives (so the persisted line carries the full block, not a partial one); tool
/// calls persist when their `toolResult` arrives (so the persisted record has both the input
/// and the output).
@MainActor
@Observable
final class ChatModel {
    // MARK: Models

    // The chat row value types live in `AnglesiteCore` as `ChatMessage`/`ChatToolCall`/… so the
    // event-accumulation reducer (`ConversationTranscript`) can be unit-tested without the App
    // shell (#161). They're re-exported here under their original names so `ChatView` and the rest
    // of this file keep referring to `ChatModel.Message`, `ChatModel.ToolCall`, etc. unchanged.
    typealias Message = ChatMessage
    typealias ToolCall = ChatToolCall
    typealias EditMetadata = ChatEditMetadata
    typealias AnnotationMetadata = ChatAnnotationMetadata

    // MARK: State

    /// The provider-agnostic chat-row store + streaming-turn reducer (`AnglesiteCore`). `ChatModel`
    /// wraps it with the SwiftUI/persistence/undo shell; mutating it (a value type) fires
    /// `@Observable` change tracking, so SwiftUI re-renders when rows change.
    private var transcript: ConversationTranscript

    /// Chat rows in display order. Forwards to ``transcript`` so `@Observable` tracks reads.
    var messages: [Message] { transcript.messages }
    private(set) var isStreaming: Bool = false
    private(set) var lastError: String?
    /// True when the user cancelled the in-flight turn — so the VoiceOver stop announcement says
    /// "stopped" rather than "complete". Set by ``cancel()``, cleared when a new turn begins.
    private(set) var wasCancelledMidTurn = false

    /// The terminal outcome of the just-ended turn, for VoiceOver's stop announcement. Derived from
    /// the same observable state `ChatView` already binds: an in-band error wins, then an explicit
    /// cancel, else the assistant's final reply text (spoken so a non-sighted user hears the answer).
    var liveAnnouncementOutcome: LiveRegionAnnouncer.ChatTurnOutcome {
        if let lastError { return .failed(reason: lastError) }
        if wasCancelledMidTurn { return .cancelled }
        let reply = messages.last(where: { $0.role == .assistant })?.content ?? ""
        return .completed(reply: reply)
    }
    /// Mirrors the last `turnComplete.usage` the assistant reported. `ChatView` shows this in the
    /// footer so the user can see token + cost telemetry without diving into the Debug pane.
    private(set) var lastUsage: TurnTelemetry?

    /// SHA of the most-recent `.edit` row whose `editMetadata.undone == false`. Drives the
    /// Undo button's enabled state — only the head row has an enabled button. Nil when no
    /// un-undone edit rows exist.
    var currentHeadSHA: String? {
        messages.reversed().first { msg in
            msg.role == .edit && (msg.editMetadata?.undone == false)
        }?.editMetadata?.commit
    }

    /// Binding for the warn-and-confirm sheet shown when the working tree drifted between
    /// the edit and the undo click. `nil` when no conflict is pending.
    var conflictPrompt: ConflictPrompt?

    struct ConflictPrompt: Identifiable, Equatable {
        let id = UUID()
        let messageID: UUID
        let commit: String
        let files: [String]
    }

    struct TurnTelemetry: Equatable {
        let inputTokens: Int
        let outputTokens: Int
        let costUSD: Double?
        let durationMs: Int?
    }

    // MARK: Dependencies

    private let siteID: String
    private let siteDirectory: URL
    /// The site's source directory, exposed read-only for CitationRowView's click-to-open.
    var siteDirectoryURL: URL { siteDirectory }
    private let assistant: any ConversationalAssistant
    private let history: ChatHistoryStore
    /// Sticky-note source. Wired to the per-site `SiteRuntime.mcpClient` in production so
    /// `loadAnnotations()` shows the same annotations the edit overlay added; tests inject a
    /// fixture closure. `nil` disables the feed (returns no annotations, no error).
    private let annotationFeed: AnnotationFeed?
    /// Resolves an annotation via the plugin's `resolve_annotation` MCP tool. Injected so tests
    /// can assert the id passed and simulate failures. `nil` disables resolution.
    typealias AnnotationResolver = @Sendable (_ id: String) async throws -> Void
    private let annotationResolver: ChatModel.AnnotationResolver?
    /// Optional. Wired to the per-site `MCPClient` in production; nil in tests where the
    /// chat has no MCP backing yet.
    private let undoCommand: UndoCommand?
    /// Bridges applied edits into the window's `UndoManager` so Edit ▸ Undo (⌘Z) reverses them
    /// (#527). `recordEdit` registers each applied edit; ⌘Z delegates back to ``undoEdit`` —
    /// the same inverse-application + conflict-detection path as the per-row Undo button.
    /// `SiteWindowModel` attaches the window's undo manager (from `@Environment(\.undoManager)`).
    ///
    /// The row is resolved by **commit SHA**, not the message UUID the record was created
    /// under: `loadHistory()` re-creates every row with a fresh UUID whenever the chat panel
    /// remounts, so a UUID captured at apply time can go stale while the edit (and its commit)
    /// remains perfectly undoable.
    @ObservationIgnored
    private(set) lazy var editUndoCoordinator = EditUndoCoordinator { [weak self] record in
        guard let self,
              let row = self.messages.first(where: { $0.editMetadata?.commit == record.commit })
        else { return .stale }
        return await self.undoEdit(messageID: row.id)
    }
    /// Commits with an `undo_edit` round trip in flight. Checked synchronously at the top of
    /// ``undoEdit`` so the per-row Undo button and ⌘Z can't double-submit the same revert —
    /// both entry points run on the main actor, and the guard closes before the first `await`.
    private var undoCommitsInFlight: Set<String> = []
    private var streamTask: Task<Void, Never>?
    /// IDs of annotations already surfaced in chat, so repeated calls to `loadAnnotations()`
    /// don't double-post the same sticky note when the user revisits a site mid-session.
    private var surfacedAnnotationIDs: Set<String> = []

    /// Test/injecting initializer: supply the assistant (typically a stub or fixture conforming to `ConversationalAssistant`)
    /// and an optional history-store override.
    init(siteID: String, siteDirectory: URL, configDirectory: URL, assistant: any ConversationalAssistant, history: ChatHistoryStore? = nil, annotationFeed: AnnotationFeed? = nil, annotationResolver: AnnotationResolver? = nil, undoCommand: UndoCommand? = nil) {
        self.siteID = siteID
        self.siteDirectory = siteDirectory
        self.assistant = assistant
        self.transcript = ConversationTranscript(providerName: assistant.capabilities.providerName)
        self.history = history ?? ChatHistoryStore(configDirectory: configDirectory)
        self.annotationFeed = annotationFeed
        self.annotationResolver = annotationResolver
        self.undoCommand = undoCommand
    }

    // MARK: API consumed by ChatView

    /// `true` while a request to put keyboard focus in the prompt input is pending (#1640). Set
    /// by `requestInputFocus()` — View ▸ Show Chat ⌃⌘K and the toolbar Chat button, via
    /// `SiteWindowModel.showChat()` — and cleared by `ChatView` through
    /// `consumeInputFocusRequest()` once it has moved focus. A latched flag rather than a
    /// fire-and-forget call because the pane is usually *not mounted yet* when the request is
    /// made (showing the pane and focusing its input is one command), so `ChatView` picks the
    /// request up as it appears; when the pane is already open, its `onChange` on this flag
    /// handles the same request instead.
    private(set) var inputFocusRequested = false

    /// Asks `ChatView` to move keyboard focus into the prompt input the next time it can.
    func requestInputFocus() {
        inputFocusRequested = true
    }

    /// Clears a pending input-focus request, returning whether there was one. One-shot: the
    /// caller (`ChatView`) is expected to focus the field iff this returns `true`.
    func consumeInputFocusRequest() -> Bool {
        defer { inputFocusRequested = false }
        return inputFocusRequested
    }

    /// Loads persisted history into `messages`. Safe to call multiple times — subsequent calls
    /// re-read from disk. Errors are recorded in `lastError`.
    func loadHistory() async {
        do {
            let entries = try await history.load()
            transcript.reset()
            for entry in entries { transcript.append(Message(persisted: entry)) }
        } catch {
            lastError = String(localized: "couldn't load history: \(error.localizedDescription)")
        }
    }

    /// Loads unresolved annotations from the plugin and surfaces each as a system message in
    /// the chat. No-op when no feed is wired up (tests without an MCP fake, or production
    /// when the preview session hasn't started yet). Idempotent: each annotation is surfaced
    /// at most once per `ChatModel` lifetime.
    func loadAnnotations() async {
        guard let annotationFeed else { return }
        let annotations: [Annotation]
        do {
            annotations = try await annotationFeed()
        } catch {
            // Surface as a non-blocking inline error; the chat is still usable.
            lastError = String(localized: "couldn't load annotations: \(error.localizedDescription)")
            return
        }
        for annotation in annotations where !annotation.resolved {
            guard !surfacedAnnotationIDs.contains(annotation.id) else { continue }
            surfacedAnnotationIDs.insert(annotation.id)
            transcript.append(.init(
                role: .annotation,
                content: ChatModel.renderAnnotation(annotation),
                timestamp: annotation.createdAt,
                annotationMetadata: .init(annotationID: annotation.id)
            ))
        }
    }

    /// Format an annotation for inline display. Single-line so the chat doesn't grow vertically
    /// when there are several pinned notes; the path + selector give the user enough context to
    /// jump back to the relevant element.
    static func renderAnnotation(_ a: Annotation) -> String {
        let location = a.sourceFile ?? "\(a.path) → \(a.selector)"
        return "📌 \(a.text) — \(location)"
    }

    /// Resolves the annotation backing `messageID`: optimistically drops the row, then calls the
    /// MCP tool. On error, restores the row and records `lastError`.
    ///
    /// The annotation id is deliberately **kept** in `surfacedAnnotationIDs` for the whole
    /// operation — including across the `await`. If it were removed first, a `loadAnnotations()`
    /// that runs during the suspension (e.g. ⌃⌘K toggles the chat panel, tearing down and
    /// re-mounting `ChatView` and refiring its `.task`) would see the id missing, fetch the
    /// still-unresolved annotation from MCP, and append a duplicate row. Leaving the id in the
    /// set makes that re-surface a no-op. On success the row is simply gone (the resolved
    /// annotation is filtered out of future feeds anyway); on failure we re-insert the one row.
    func resolveAnnotation(messageID: UUID) async {
        guard let target = messages.first(where: { $0.id == messageID }),
              let meta = target.annotationMetadata,
              annotationResolver != nil else { return }
        guard let removed = transcript.remove(id: messageID) else { return }  // optimistic: drop from the feed
        do {
            try await annotationResolver?(meta.annotationID)
        } catch {
            // The row may have shifted during the suspension (concurrent resolve, streaming send,
            // loadAnnotations). `insertByTimestamp` re-locates the chronological position rather
            // than trusting a stale index.
            transcript.insertByTimestamp(removed)
            lastError = String(localized: "couldn't resolve annotation: \(error.localizedDescription)")
        }
    }

    /// Sends a user prompt to the agent and consumes the resulting event stream. No-op while
    /// a turn is in flight.
    func send(_ prompt: String, searchOptions: SiteKnowledgeIndex.SearchOptions = .init()) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        lastError = nil
        wasCancelledMidTurn = false
        // `beginTurn` appends the user prompt and an empty assistant row (which streamed events
        // extend), marks the latter in-flight, and returns the user row so we persist exactly it.
        let userMessage = transcript.beginTurn(userPrompt: trimmed)
        persist(userMessage)

        isStreaming = true
        streamTask = Task { @MainActor [weak self] in
            await self?.consumeAssistantStream(prompt: trimmed, searchOptions: searchOptions)
        }
    }

    /// Append a `.edit` row from a successful `EditReply`. The reply must have a non-nil
    /// `commit` field — `MCPApplyEditRouter.onEdit` only fires for those. Persists the row
    /// via `ChatHistoryStore` with the `messageID` in metadata so future `undone` sidecars
    /// can find it on reload.
    func recordEdit(_ reply: EditReply) {
        guard let file = reply.file, let commit = reply.commit else { return }
        let metadata = EditMetadata(file: file, commit: commit, undone: false)
        let message = Message(
            role: .edit,
            content: "Edited \(file)",
            editMetadata: metadata
        )
        transcript.append(message)
        editUndoCoordinator.registerApplied(.init(file: file, commit: commit))
        let entry = ChatHistoryStore.Entry(
            timestamp: message.timestamp,
            role: .edit,
            content: message.content,
            metadata: [
                "file": file,
                "commit": commit,
                "messageID": message.id.uuidString,
            ]
        )
        Task { [history] in try? await history.append(entry) }
    }

    /// Call `undo_edit` for the message identified by `messageID`. On success, flip the
    /// row's `undone` flag and persist a sidecar. On working-tree drift, set `conflictPrompt`
    /// so the view shows a sheet. On failure, append an `.error` system message.
    ///
    /// The returned outcome drives ``editUndoCoordinator``'s re-arm decision when the call
    /// came from ⌘Z (the row-button path discards it): `.undone` spends the record,
    /// `.retryable` keeps the edit reachable via ⌘Z (failure, conflict sheet pending, MCP
    /// down, or another revert already in flight for this commit), `.stale` drops it (the
    /// record no longer maps to an undoable row).
    @discardableResult
    func undoEdit(messageID: UUID, force: Bool = false) async -> EditUndoCoordinator.UndoOutcome {
        guard let target = messages.first(where: { $0.id == messageID }),
              target.role == .edit,
              let metadata = target.editMetadata,
              !metadata.undone
        else { return .stale }
        guard let undoCommand else {
            lastError = String(localized: "Undo unavailable: MCP not running.")
            return .retryable
        }
        // Double-submit guard: the row button and ⌘Z are independent entry points into this
        // function, and `metadata.undone` only flips after the `await` below — so without
        // this, a click + reflexive ⌘Z would send two concurrent reverts for the same commit.
        // Checked and inserted synchronously (no suspension) on the main actor.
        guard !undoCommitsInFlight.contains(metadata.commit) else { return .retryable }
        undoCommitsInFlight.insert(metadata.commit)
        defer { undoCommitsInFlight.remove(metadata.commit) }
        let result = await undoCommand.undo(commit: metadata.commit, force: force)
        switch result {
        case .success(let newCommit):
            transcript.update(id: messageID) { $0.editMetadata?.undone = true }
            // Drop any still-pending ⌘Z record for this edit (the per-row Undo button path,
            // or a record re-armed after an earlier failed/conflicted ⌘Z). No-op when the
            // undo *came from* ⌘Z — the coordinator consumed its record first.
            editUndoCoordinator.invalidate(commit: metadata.commit)
            Task { [history] in
                try? await history.appendUndone(messageID: messageID, newCommit: newCommit)
            }
            return .undone
        case .workingTreeModified(let files):
            conflictPrompt = ConflictPrompt(messageID: messageID, commit: metadata.commit, files: files)
            // Not undone yet: the sheet is pending. Re-arming keeps ⌘Z truthful if the user
            // cancels; if they confirm, the forced retry's success invalidates by commit.
            return .retryable
        case .failed(let reason, let detail):
            let errorContent = String(localized: "Couldn't undo: \(detail) (\(reason))")
            transcript.append(Message(role: .error, content: errorContent))
            lastError = errorContent
            return .retryable
        }
    }

    /// Called when the user clicks "Undo anyway" on the conflict sheet. Retries the undo
    /// with `force: true` and dismisses the sheet.
    func confirmConflictUndo() async {
        guard let prompt = conflictPrompt else { return }
        conflictPrompt = nil
        await undoEdit(messageID: prompt.messageID, force: true)
    }

    /// Called when the user clicks "Cancel" on the conflict sheet.
    func dismissConflictPrompt() {
        conflictPrompt = nil
    }

    /// Stops the in-flight turn. The current assistant message is marked finished as-is.
    func cancel() {
        wasCancelledMidTurn = true
        streamTask?.cancel()
        Task { await assistant.cancel() }
    }

    /// Clears in-memory messages, resets the assistant's session, and truncates the history file.
    func resetConversation() async {
        cancel()
        streamTask = nil
        transcript.reset()
        // The rows backing the window's ⌘Z records are gone (and the truncated history can't
        // resurrect them) — drop the records too, or ⌘Z would silently consume entries whose
        // reverts can no longer be located.
        editUndoCoordinator.invalidateAll()
        await assistant.resetSession()
        do { try await history.clear() } catch { lastError = String(localized: "couldn't clear history: \(error.localizedDescription)") }
    }

    // MARK: Event consumption

    private func consumeAssistantStream(prompt: String, searchOptions: SiteKnowledgeIndex.SearchOptions = .init()) async {
        let stream: AsyncStream<AssistantEvent>
        do {
            let context = AssistantContext(siteID: siteID, siteDirectory: siteDirectory, searchOptions: searchOptions)
            stream = try await assistant.converse(prompt: prompt, context: context)
        } catch {
            transcript.endTurn()
            isStreaming = false
            lastError = String(localized: "couldn't start \(assistant.capabilities.providerName): \(error.localizedDescription)")
            return
        }

        for await event in stream {
            // The provider-agnostic accumulation (text deltas, tool pairing, error/cancel rows,
            // usage capture) lives in `ConversationTranscript` (AnglesiteCore, fully unit-tested);
            // `ChatModel` just forwards each event and mirrors the resulting telemetry into the
            // `@Observable` UI properties `ChatView` binds to.
            transcript.apply(event)
            syncObservedTelemetry()
        }

        // Persist the assistant turn now that it's complete. Empty text + no tool calls means the
        // user sent a no-op or got a session-error — we still persist for audit.
        if let finalMessage = transcript.endTurn() {
            persist(finalMessage)
        }
        isStreaming = false
    }

    /// Mirrors the transcript's error + usage telemetry into the `@Observable` properties bound by
    /// `ChatView`. Called after each applied event; the transcript is the source of truth during a
    /// turn (out-of-band setters — load/undo/annotation failures — write `lastError` directly).
    private func syncObservedTelemetry() {
        lastError = transcript.lastError
        if let usage = transcript.lastUsage {
            lastUsage = TurnTelemetry(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                costUSD: usage.costUSD,
                durationMs: usage.durationMs
            )
        }
    }

    // MARK: Helpers

    private func persist(_ message: Message) {
        // Citations are ephemeral per-session (re-computed on each turn), like annotations.
        guard message.role != .citation else { return }
        let role: ChatHistoryStore.Role = {
            switch message.role {
            case .user: return .user
            case .assistant: return .assistant
            // `.system`/`.error`/`.annotation`/`.citation` are never routed through `persist` —
            // they're appended directly or guarded above. Annotations are reloaded fresh from
            // MCP each session via `loadAnnotations()`, and citations are re-computed per turn.
            // This arm only keeps the switch exhaustive.
            case .system, .error, .annotation, .citation: return .assistant
            case .edit: return .edit
            }
        }()
        var metadata: [String: String] = [:]
        if !message.toolCalls.isEmpty {
            metadata["tool_calls"] = message.toolCalls.count.description
        }
        if let edit = message.editMetadata {
            metadata["file"] = edit.file
            metadata["commit"] = edit.commit
            metadata["messageID"] = message.id.uuidString
        }
        let entry = ChatHistoryStore.Entry(
            timestamp: message.timestamp,
            role: role,
            content: message.content,
            metadata: metadata.isEmpty ? nil : metadata
        )
        // Persist async-fire-and-forget: an I/O failure is non-blocking for the UI.
        Task { [history] in try? await history.append(entry) }
    }
}

private extension ChatModel.Message {
    init(persisted entry: ChatHistoryStore.Entry) {
        let role: ChatModel.Message.Role = {
            switch entry.role {
            case .user: return .user
            case .assistant: return .assistant
            case .tool: return .assistant
            case .edit: return .edit
            }
        }()
        var editMetadata: ChatModel.EditMetadata?
        if entry.role == .edit,
           let file = entry.metadata?["file"],
           let commit = entry.metadata?["commit"] {
            let undone = entry.metadata?["undone"] == "true"
            editMetadata = ChatModel.EditMetadata(file: file, commit: commit, undone: undone)
        }
        self.init(
            role: role,
            content: entry.content,
            timestamp: entry.timestamp,
            editMetadata: editMetadata
        )
    }
}
