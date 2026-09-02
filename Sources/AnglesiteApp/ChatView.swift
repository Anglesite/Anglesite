import SwiftUI
import AppKit
import AnglesiteCore
#if compiler(>=6.4)
import FoundationModels
#endif

/// Chat panel UI. Renders the live conversation between the user and the site's
/// ``ConversationalAssistant`` backed by Foundation Models. Designed to live in a right-hand pane
/// of the main window so the user can see the preview and chat side by side.
///
/// Markdown is rendered via SwiftUI's native `AttributedString(markdown:)` — covers bold,
/// italic, code spans, and links without pulling in a markdown library. Multi-line code blocks
/// are surfaced as plain monospace (the inline strategy fails on those, and that's fine for
/// v0.5; #25 follow-ups can introduce a richer renderer if needed).
struct ChatView: View {
    @Bindable var model: ChatModel
    /// Resolves a citation's path to a Site Graph Explorer node and reveals it there; returns
    /// `false` when the path isn't a graph node, so the click falls back to opening the file
    /// (#314). `nil` in previews/tests that don't wire a graph explorer.
    var revealCitation: ((String) -> Bool)?

    /// Binds the prompt input. Lives in the view (not the model) because it's pure transient
    /// UI state; the model only sees the final string when the user hits Send.
    @State private var draft: String = ""
    @State private var activeKinds: Set<SiteKnowledgeIndex.Document.Kind>?
    @FocusState private var inputFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagesList
            Divider()
            inputBar
        }
        .frame(minWidth: 320, idealWidth: 420)
        .background(Color(NSColor.windowBackgroundColor))
        .task {
            await model.loadHistory()
            await model.loadAnnotations()
        }
        // Input focus on request (#1640): View ▸ Show Chat ⌃⌘K / the toolbar Chat button latch a
        // request on the model *before* this pane is mounted, so the appear-time `.task` picks
        // it up (`.task`, not `.onAppear`, so the field has finished laying out — the same
        // pattern the New Community / navigator-rename fields use); the `onChange` covers a
        // request that arrives while the pane is already open. Both consume the request so it
        // can't re-fire on a later remount.
        .task { focusInputIfRequested() }
        .onChange(of: model.inputFocusRequested) { _, requested in
            if requested { focusInputIfRequested() }
        }
        .sheet(item: $model.conflictPrompt) { prompt in
            VStack(alignment: .leading, spacing: 12) {
                Text("File modified outside Anglesite")
                    .font(.headline)
                Text("\(prompt.files.joined(separator: ", ")) has been changed since this edit. Undoing will overwrite those changes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { model.dismissConflictPrompt() }
                    Button("Undo anyway", role: .destructive) {
                        Task { await model.confirmConflictUndo() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(.secondary)
            Text("Chat").font(.headline)
            Spacer()
            if let usage = model.lastUsage {
                Text(usageSummary(usage))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Token usage and cost")
                    .accessibilityValue(usageSummary(usage))
            }
            Menu {
                Button("Reset conversation", role: .destructive) {
                    Task { await model.resetConversation() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Messages

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.messages) { message in
                        MessageRow(message: message, model: model, revealCitation: revealCitation)
                            .id(message.id)
                    }
                    if let error = model.lastError, !model.messages.contains(where: { $0.role == .error && $0.content == error }) {
                        // Surface a one-shot inline error if the model has set lastError but
                        // didn't materialize a message for it (e.g. couldn't even spawn).
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    // Sentinel for scroll-anchoring during streaming. Tracks the bottom edge
                    // even as the latest assistant message grows char-by-char.
                    Color.clear
                        .frame(height: 1)
                        .id("__bottom__")
                }
                .padding(12)
            }
            .onChange(of: model.messages.last?.id) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("__bottom__", anchor: .bottom)
                }
            }
            .onChange(of: model.messages.last?.content) { _, _ in
                // Stream characters extend the last message; re-anchor on each chunk.
                proxy.scrollTo("__bottom__", anchor: .bottom)
            }
            // VoiceOver live region: announce the *transitions* into and out of streaming, so a
            // non-sighted user knows a response started, and hears the answer when it finishes —
            // without watching tokens arrive. Keyed off `isStreaming` (not message content) so it
            // fires twice per turn, never per-chunk; the stop announcement speaks the actual reply
            // (or the failure/cancel reason). See `LiveRegionAnnouncer` for the rationale.
            .onChange(of: model.isStreaming) { wasStreaming, isStreaming in
                guard AppSettings.shared.announcesLiveUpdates else { return }
                if let start = LiveRegionAnnouncer.chatStartAnnouncement(
                    wasStreaming: wasStreaming, isStreaming: isStreaming) {
                    AccessibilityNotification.Announcement(start).post()
                }
                if let stop = LiveRegionAnnouncer.chatStopAnnouncement(
                    wasStreaming: wasStreaming, isStreaming: isStreaming,
                    outcome: model.liveAnnouncementOutcome) {
                    AccessibilityNotification.Announcement(stop).post()
                }
            }
        }
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            kindFilterMenu
            TextField("Ask the assistant…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit(submitIfReady)
                .disabled(model.isStreaming)
            if model.isStreaming {
                Button("Cancel response", systemImage: "stop.fill") {
                    model.cancel()
                }
                .labelStyle(.iconOnly)
                .help("Cancel response")
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button("Send", systemImage: "paperplane.fill") {
                    submitIfReady()
                }
                .labelStyle(.iconOnly)
                .help("Send (⏎)")
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var kindFilterMenu: some View {
        Menu {
            ForEach(SiteKnowledgeIndex.Document.Kind.allCases, id: \.self) { kind in
                Toggle(kind.rawValue.capitalized, isOn: kindBinding(for: kind))
            }
            Divider()
            Button("Clear filter") { activeKinds = nil }
                .disabled(activeKinds == nil)
        } label: {
            Image(systemName: activeKinds != nil
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(activeKinds.map { "Filtering: \($0.map { $0.rawValue }.sorted().joined(separator: ", "))" }
              ?? "Filter retrieval by content type")
        .accessibilityLabel("Content type filter")
        .accessibilityValue(activeKinds.map { "\($0.count) selected" } ?? "All types")
    }

    private func kindBinding(for kind: SiteKnowledgeIndex.Document.Kind) -> Binding<Bool> {
        Binding(
            get: { activeKinds?.contains(kind) ?? false },
            set: { isOn in
                if isOn {
                    var kinds = activeKinds ?? []
                    kinds.insert(kind)
                    activeKinds = kinds
                } else {
                    activeKinds?.remove(kind)
                    if activeKinds?.isEmpty == true { activeKinds = nil }
                }
            }
        )
    }

    private func focusInputIfRequested() {
        guard model.consumeInputFocusRequest() else { return }
        inputFocused = true
    }

    private func submitIfReady() {
        let prompt = draft
        let options = activeKinds.map { SiteKnowledgeIndex.SearchOptions(kinds: $0) } ?? .init()
        model.send(prompt, searchOptions: options)
        // Clear input only after a successful start (model.isStreaming flipped to true).
        if !model.isStreaming { return }
        draft = ""
        inputFocused = true
    }

    private func usageSummary(_ u: ChatModel.TurnTelemetry) -> String {
        var parts: [String] = ["↓\(u.inputTokens) ↑\(u.outputTokens)"]
        if let cost = u.costUSD { parts.append(String(format: "$%.4f", cost)) }
        if let ms = u.durationMs { parts.append("\(ms / 1000).\(String(format: "%01d", (ms % 1000) / 100))s") }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - Shared formatter

// Configured once and only read via `localizedString(for:relativeTo:)` afterward. Apple doesn't
// document `RelativeDateTimeFormatter` as thread-safe, so `nonisolated(unsafe)` is a deliberate
// choice asserting that never-mutated-after-init invariant.
private nonisolated(unsafe) let sharedRelativeTimeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
}()

// MARK: - Message row

private struct MessageRow: View {
    let message: ChatModel.Message
    let model: ChatModel
    var revealCitation: ((String) -> Bool)?

    var body: some View {
        if message.role == .edit {
            editRow
        } else if message.role == .annotation {
            AnnotationRowView(message: message, model: model)
        } else if message.role == .citation {
            if let meta = message.citationMetadata {
                CitationRowView(citations: meta.citations, siteDirectory: model.siteDirectoryURL, revealCitation: revealCitation)
            }
        } else {
            HStack {
                if message.role == .user { Spacer(minLength: 32) }
                VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                    bubble
                    ForEach(message.toolCalls) { call in
                        ToolCallCard(call: call)
                    }
                }
                if message.role != .user { Spacer(minLength: 32) }
            }
        }
    }

    @ViewBuilder
    private var editRow: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.content)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Text(relativeTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let metadata = message.editMetadata {
                if metadata.undone {
                    Text("Undone")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    Button("Undo") {
                        Task { await model.undoEdit(messageID: message.id) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(metadata.commit != model.currentHeadSHA)
                    .accessibilityLabel("Undo this edit")
                    .accessibilityHint(metadata.commit != model.currentHeadSHA
                                       ? "Unavailable — newer edits have been made since"
                                       : "")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var relativeTime: String {
        sharedRelativeTimeFormatter.localizedString(for: message.timestamp, relativeTo: .now)
    }

    @ViewBuilder
    private var bubble: some View {
        if message.content.isEmpty && !message.toolCalls.isEmpty {
            EmptyView()
        } else {
            Text(attributedContent)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleBackground)
                .foregroundStyle(bubbleForeground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                // Prefix the spoken text with the speaker so VoiceOver users can follow the
                // back-and-forth; the visual layout (left/right alignment) conveys this sightedly.
                .accessibilityLabel(accessibilitySpokenContent)
        }
    }

    /// Role-prefixed plain text for VoiceOver. Uses the raw message string (not the attributed
    /// markdown) so symbols and code fences don't garble the reading.
    private var accessibilitySpokenContent: String {
        switch message.role {
        case .user:      return "You said: \(message.content)"
        case .assistant: return "Assistant said: \(message.content)"
        case .error:     return "Error: \(message.content)"
        case .system:    return "System: \(message.content)"
        case .edit, .annotation: return message.content
        case .citation: return "Retrieved context"
        }
    }

    private var attributedContent: AttributedString {
        if let attributed = try? AttributedString(markdown: message.content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attributed
        }
        return AttributedString(message.content)
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user: return Color.accentColor.opacity(0.18)
        case .assistant: return Color(NSColor.controlBackgroundColor)
        case .system: return Color.secondary.opacity(0.12)
        case .error: return Color.red.opacity(0.15)
        case .edit: return Color.secondary.opacity(0.06)  // editRow handles .edit rendering; this is unreachable
        case .annotation: return Color.secondary.opacity(0.12)
        case .citation: return Color.secondary.opacity(0.06)  // citationRow handles rendering; unreachable
        }
    }

    private var bubbleForeground: Color {
        switch message.role {
        case .error: return .red
        default: return .primary
        }
    }
}

// MARK: - Annotation row

private struct AnnotationRowView: View {
    let message: ChatModel.Message
    let model: ChatModel
    @State private var isResolving = false

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.orange.opacity(0.5))
                .frame(width: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.content)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Text(relativeTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Resolve") {
                isResolving = true
                Task {
                    await model.resolveAnnotation(messageID: message.id)
                    isResolving = false
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isResolving)
            .accessibilityLabel("Resolve this annotation")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var relativeTime: String {
        sharedRelativeTimeFormatter.localizedString(for: message.timestamp, relativeTo: .now)
    }
}

// MARK: - Tool-call card

private struct ToolCallCard: View {
    let call: ChatModel.ToolCall
    @State private var expanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if !call.inputDisplay.isEmpty {
                    Text("Input")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(call.inputDisplay)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                if let result = call.result {
                    Text(call.isError ? "Error" : "Result")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(call.isError ? .red : .secondary)
                    Text(result)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                            .accessibilityHidden(true)
                        Text("running…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: call.isError ? "exclamationmark.triangle.fill" : (call.result == nil ? "wrench.and.screwdriver" : "wrench.and.screwdriver.fill"))
                    .foregroundStyle(call.isError ? .red : .secondary)
                    .accessibilityHidden(true)
                Text(call.name)
                    .font(.callout.weight(.medium))
                    // Roll the tool state into the disclosure label so a collapsed card still
                    // announces error/running/done without the icon (now hidden) carrying it.
                    .accessibilityLabel("\(call.name) tool")
                    .accessibilityValue(call.isError ? "Error"
                                        : (call.result == nil ? "Running" : "Finished"))
                if call.result == nil {
                    ProgressView().controlSize(.mini)
                        .accessibilityHidden(true)
                }
                Spacer()
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private actor PreviewAssistant: ConversationalAssistant {
    nonisolated var capabilities: AssistantCapabilities {
        AssistantCapabilities(
            supportsStreaming: true,
            supportsStructuredOutput: false,
            supportsVision: false,
            supportsTools: false,
            maxContextTokens: nil,
            providerName: "Preview"
        )
    }

    func generate(prompt: String, context: AssistantContext) async throws -> AsyncThrowingStream<String, Error> {
        _ = context
        return AsyncThrowingStream { continuation in
            continuation.yield("Preview response to: \(prompt)")
            continuation.finish()
        }
    }

    #if compiler(>=6.4)
    func generateStructured<T: Generable & Sendable>(
        prompt: String,
        context: AssistantContext,
        resultType: T.Type
    ) async throws -> T {
        _ = prompt
        _ = context
        _ = resultType
        throw AssistantError.unsupported("Preview assistant does not support structured output")
    }
    #endif

    func converse(prompt: String, context: AssistantContext) async throws -> AsyncStream<AssistantEvent> {
        _ = context
        return AsyncStream { continuation in
            continuation.yield(.started(model: "Preview", toolNames: []))
            continuation.yield(.textDelta("Preview response to: \(prompt)"))
            continuation.yield(.turnComplete(nil))
            continuation.finish()
        }
    }

    func cancel() async {}
    func resetSession() async {}
}

#Preview {
    ChatView(model: ChatModel(
        siteID: "preview",
        siteDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
        configDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
        assistant: PreviewAssistant()
    ))
        .frame(width: 420, height: 560)
}
