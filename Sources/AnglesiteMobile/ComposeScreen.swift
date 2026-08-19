// Sources/AnglesiteMobile/ComposeScreen.swift
import SwiftUI
import UIKit
import PhotosUI
import Network
import UniformTypeIdentifiers
import AnglesiteIOS
import AnglesiteCore

/// The composer (#869): a registry-driven typed form over one post, with the Markdown body
/// surface and the Save Draft / Publish actions. All state lives in `PostComposerModel`
/// (`AnglesiteIOS`); this screen renders its phase and forwards intents.
struct ComposeScreen: View {
    @Bindable var model: PostComposerModel
    /// Called after a successful send so the enclosing list refreshes.
    var onSent: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        MicropubEntryForm(model: model)
            .navigationTitle(model.descriptor.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Save Draft") { Task { await model.saveDraft(); notifyIfSent() } }
                        .disabled(isSending)
                    Button("Publish") { Task { await model.publish(); notifyIfSent() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSending)
                }
            }
            .safeAreaInset(edge: .bottom) { phaseBanner }
            .confirmationDialog(
                Text("This post changed on your site since you started editing."),
                isPresented: conflictPresented,
                titleVisibility: .visible
            ) {
                Button("Keep My Version") { Task { await model.keepMine(); notifyIfSent() } }
                Button("Use the Site's Version", role: .destructive) { model.takeTheirs() }
                Button("Decide Later", role: .cancel) {}
            } message: {
                Text("Keeping your version replaces the site's copy. Using the site's version discards the changes you made here.")
            }
            .onChange(of: scenePhase) { _, phase in
                // §3's restore contract: an interrupted session keeps its in-progress draft.
                if phase == .background { model.persistDraft() }
            }
            .task(id: isWaitingForNetwork) {
                guard isWaitingForNetwork else { return }
                await Self.waitForNetwork()
                guard !Task.isCancelled else { return }
                await model.retry()
                notifyIfSent()
            }
    }

    private var isSending: Bool {
        if case .sending = model.phase { return true }
        return false
    }

    private var isWaitingForNetwork: Bool {
        if case .waitingForNetwork = model.phase { return true }
        return false
    }

    private var conflictPresented: Binding<Bool> {
        Binding(
            get: {
                if case .conflict = model.phase { return true }
                return false
            },
            set: { presented in
                // Dismissing without choosing keeps editing; the conflict re-arms on next send.
                if !presented, case .conflict = model.phase { model.resumeEditing() }
            }
        )
    }

    private func notifyIfSent() {
        switch model.phase {
        case .savedDraft, .publishedRebuilding: onSent()
        default: break
        }
    }

    /// The phase strip under the form: sending progress, the explicit waiting-for-network state,
    /// publish/bake status, or a terminal failure. One at a time, matching the model's phase.
    @ViewBuilder
    private var phaseBanner: some View {
        switch model.phase {
        case .editing:
            EmptyView()
        case .sending:
            banner { ProgressView(); Text("Sending to your site…") }
        case .waitingForNetwork:
            // Deliberately no delivery-time promise (design § open questions).
            banner(role: .warning) {
                Image(systemName: "wifi.slash")
                Text("Waiting for network — your draft is saved on this device.")
                Spacer()
                Button("Retry") { Task { await model.retry(); notifyIfSent() } }
            }
        case .authRequired:
            banner(role: .warning) {
                Image(systemName: "person.badge.key")
                Text("Your site needs you to sign in again.")
            }
        case .failed(let message):
            banner(role: .error) {
                Image(systemName: "exclamationmark.triangle")
                Text(verbatim: message)
                Spacer()
                Button("Dismiss") { model.resumeEditing() }
            }
        case .savedDraft:
            banner {
                Image(systemName: "checkmark.circle")
                Text("Draft saved to your site.")
                Spacer()
                Button("Keep Editing") { model.resumeEditing() }
            }
        case .publishedRebuilding:
            // "Published — site rebuilding": the bake is in flight; never a faked live preview.
            banner {
                ProgressView()
                Text("Published — site rebuilding.")
                Spacer()
                Button("Keep Editing") { model.resumeEditing() }
            }
        case .conflict:
            EmptyView()   // rendered by the confirmation dialog above
        }
    }

    private enum BannerRole { case info, warning, error }

    private func banner(
        role: BannerRole = .info, @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(spacing: 8) { content() }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
    }

    /// Resolves when the network path is satisfied — the waiting-for-network state's automatic
    /// retry trigger while the app is running. (OS-scheduled background retry after the app
    /// exits is the design's noted follow-up; the queued draft persists either way.)
    ///
    /// Honors task cancellation: SwiftUI cancels the enclosing `.task` when the composer goes
    /// away, and a bare `withCheckedContinuation` would leave the monitor and a suspended
    /// continuation alive until the device's network actually returned (#1370 review). The
    /// caller re-checks `Task.isCancelled` after this returns, so an early cancel-resume never
    /// triggers a retry.
    private static func waitForNetwork() async {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        let gate = ContinuationGate()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gate.arm(continuation)
                monitor.pathUpdateHandler = { path in
                    if path.status == .satisfied { gate.resume() }
                }
                monitor.start(queue: DispatchQueue(label: "io.dwk.anglesite.network-wait"))
            }
        } onCancel: {
            gate.resume()
        }
    }
}

/// Resumes a `Void` continuation exactly once, from whichever of the path-satisfied callback or
/// the cancellation handler fires first — both race on background queues, and a double resume
/// is a crash while a dropped one is a leak.
private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    /// Set when `resume()` ran before `arm(_:)` — cancellation can fire before the
    /// continuation exists; arming after that resumes immediately.
    private var resumedEarly = false

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if resumedEarly {
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume() {
        lock.lock()
        guard let continuation else {
            resumedEarly = true
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume()
    }
}

/// The schema-driven form body — one control per field `Kind`, ordered by the descriptor,
/// mirroring the Mac's `TypedEntryForm` with iOS idioms (`PhotosPicker`/`fileImporter` where the
/// Mac uses `NSOpenPanel`).
struct MicropubEntryForm: View {
    @Bindable var model: PostComposerModel

    var body: some View {
        Form {
            Section {
                Picker("Visibility", selection: $model.visibility) {
                    Text("Public").tag(MicropubPostVisibility.public)
                    Text("Restricted to Contacts").tag(MicropubPostVisibility.contacts)
                }
                // Says plainly that picking "Restricted" doesn't yet gate who can read the post —
                // the site's authenticated read gate is a later slice of #963, and an owner
                // shouldn't infer enforcement from the label alone.
                if model.visibility == .contacts {
                    Text("Restricted posts are stored on your site's server, not in git. Contact-only access turns on once your site's read gate ships.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(scalarFields, id: \.name) { field in
                control(for: field)
            }
            if let body = bodyField {
                Section("Body") {
                    MarkdownTextView(
                        text: model.textBinding(body.name),
                        documentId: model.postURL?.absoluteString ?? model.descriptor.id,
                        fitsContent: true
                    )
                    .id(model.postURL?.absoluteString ?? model.descriptor.id)
                    .frame(minHeight: 160)
                }
            }
        }
    }

    /// `draft` is omitted: its wire form is `post-status`, which the Save Draft / Publish
    /// actions stamp — a checkbox alongside those buttons would fight them.
    private var scalarFields: [ContentTypeField] {
        model.descriptor.fields.filter { $0.kind != .markdown && $0.name != "draft" }
    }

    private var bodyField: ContentTypeField? {
        model.descriptor.fields.first { $0.kind == .markdown }
    }

    @ViewBuilder
    private func control(for field: ContentTypeField) -> some View {
        let label = field.name + (field.required ? " *" : "")
        switch field.kind {
        case .string, .language:
            TextField(label, text: model.textBinding(field.name))
        case .url:
            TextField(label, text: model.textBinding(field.name))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .image:
            ImageFieldControl(label: label, model: model, text: model.textBinding(field.name))
        case .text:
            VStack(alignment: .leading) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                TextField("", text: model.textBinding(field.name), axis: .vertical)
                    .lineLimit(2...6)
            }
        case .bool:
            Toggle(label, isOn: model.boolBinding(field.name))
        case .date, .datetime:
            DatePicker(
                label, selection: model.dateBinding(field.name),
                displayedComponents: field.kind == .date ? [.date] : [.date, .hourAndMinute])
        case .number:
            TextField(label, text: model.numberBinding(field.name))
                .keyboardType(.decimalPad)
        case .stringArray:
            StringListEditor(title: label, items: model.listBinding(field.name), model: nil)
        case .imageArray:
            StringListEditor(title: label, items: model.listBinding(field.name), model: model)
        case .objectArray(let memberFields):
            ObjectArrayEditor(
                title: label, memberFields: memberFields,
                records: model.recordsBinding(field.name))
        case .markdown:
            EmptyView()   // handled by the Body section
        }
    }
}

/// One image field: the value (a URL once uploaded) plus a `PhotosPicker` and a Files chooser —
/// the iOS replacements for the Mac form's `NSOpenPanel`. Picked images upload through the
/// site's media endpoint immediately (guarded by `MediaUploadGuard`); the resulting URL becomes
/// the field's value.
private struct ImageFieldControl: View {
    let label: String
    let model: PostComposerModel
    @Binding var text: String
    @State private var pickerItem: PhotosPickerItem?
    @State private var importerPresented = false
    @State private var uploading = false
    @State private var uploadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(label, text: $text)
                if uploading {
                    ProgressView()
                } else {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Image(systemName: "photo.badge.plus")
                    }
                    .accessibilityLabel(Text("Choose Photo"))
                    Button {
                        importerPresented = true
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel(Text("Choose File"))
                }
            }
            if let uploadError {
                Text(verbatim: uploadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await uploadPicked(item); pickerItem = nil }
        }
        .fileImporter(isPresented: $importerPresented, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            Task { await uploadFile(at: url) }
        }
        .buttonStyle(.borderless)
    }

    private func uploadPicked(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            uploadError = String(localized: "That photo couldn't be read.")
            return
        }
        // Photos exports are commonly HEIC, which browsers don't render — transcode to JPEG
        // before the guard sees it (the guard's allow-list is web-servable formats only).
        guard let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.9)
        else {
            uploadError = String(localized: "That photo couldn't be converted for the web.")
            return
        }
        await upload(data: jpeg, filename: "photo.jpg", mimeType: "image/jpeg")
    }

    private func uploadFile(at url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            uploadError = String(localized: "That file couldn't be read.")
            return
        }
        await upload(
            data: data, filename: url.lastPathComponent, mimeType: Self.mimeType(for: url))
    }

    private func upload(data: Data, filename: String, mimeType: String) async {
        uploading = true
        uploadError = nil
        defer { uploading = false }
        do {
            let url = try await model.uploadImage(
                data: data, filename: filename, mimeType: mimeType)
            text = url.absoluteString
        } catch let error as PostComposerModel.MediaUploadError {
            uploadError = Self.describe(error)
        } catch {
            uploadError = error.localizedDescription
        }
    }

    private static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }

    private static func describe(_ error: PostComposerModel.MediaUploadError) -> String {
        switch error {
        case .rejected(.tooLarge(let bytes)):
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(bytes), countStyle: .file)
            return String(localized: "That image is \(size) — the limit is 25 MB.")
        case .rejected(.unsupportedFormat(let mimeType)):
            return String(localized: "\(mimeType) images can't be shown on the web.")
        case .rejected(.empty):
            return String(localized: "That file is empty.")
        case .transport(let micropubError) where micropubError.requiresReauthorization:
            return String(localized: "Your site needs you to sign in again.")
        case .transport:
            return String(localized: "The upload didn't go through — try again.")
        }
    }
}

/// The iOS counterpart of the Mac form's list editor for `stringArray`/`imageArray` fields.
/// Rows carry stable UUID identity so deleting one never re-binds a survivor's editor. When
/// `model` is non-nil the field is image-flavored and each row offers the photo picker.
private struct StringListEditor: View {
    let title: String
    @Binding var items: [String]
    /// Non-nil enables per-row image picking (imageArray fields).
    let model: PostComposerModel?

    private struct Row: Identifiable, Equatable {
        let id = UUID()
        var value: String
    }
    @State private var rows: [Row] = []
    @State private var pickerItem: PhotosPickerItem?
    @State private var uploadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach($rows) { $row in
                HStack {
                    TextField("", text: $row.value)
                    Button(role: .destructive) {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .accessibilityLabel(Text("Remove"))
                }
            }
            HStack {
                Button {
                    rows.append(Row(value: ""))
                } label: {
                    Label("Add", systemImage: "plus.circle")
                }
                if model != nil {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Add Photo", systemImage: "photo.badge.plus")
                    }
                }
            }
            if let uploadError {
                Text(verbatim: uploadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .buttonStyle(.borderless)
        .onAppear { syncRowsFromItems() }
        .onChange(of: items) { _, new in
            if new != rows.map(\.value) { rows = new.map(Row.init(value:)) }
        }
        .onChange(of: rows) { _, new in
            let mapped = new.map(\.value)
            if mapped != items { items = mapped }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item, let model else { return }
            Task {
                await uploadPicked(item, model: model)
                pickerItem = nil
            }
        }
    }

    private func syncRowsFromItems() {
        if items != rows.map(\.value) { rows = items.map(Row.init(value:)) }
    }

    private func uploadPicked(_ item: PhotosPickerItem, model: PostComposerModel) async {
        uploadError = nil
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.9)
        else {
            uploadError = String(localized: "That photo couldn't be read.")
            return
        }
        do {
            let url = try await model.uploadImage(
                data: jpeg, filename: "photo.jpg", mimeType: "image/jpeg")
            rows.append(Row(value: url.absoluteString))
        } catch {
            uploadError = String(localized: "The upload didn't go through — try again.")
        }
    }
}

/// The iOS counterpart of the Mac form's `objectArray` editor — one block per record, member
/// fields inline, stable row identity. The member-kind convention (no markdown/array/nested
/// kinds inside a record) is enforced the same way: unsupported kinds fail visibly.
private struct ObjectArrayEditor: View {
    let title: String
    let memberFields: [ContentTypeField]
    @Binding var records: [[String: TypedContentEditor.FieldValue]]

    private struct Row: Identifiable, Equatable {
        let id = UUID()
        var values: [String: TypedContentEditor.FieldValue]
    }
    @State private var rows: [Row] = []
    /// Per-row, per-field mid-edit number drafts — see the Mac editor's identical buffer.
    @State private var numberDrafts: [Row.ID: [String: String]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach($rows) { $row in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(memberFields, id: \.name) { field in
                        memberControl(for: field, in: $row.values, rowID: row.id)
                    }
                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            removeRow(row.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .accessibilityLabel(Text("Remove"))
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            }
            Button {
                rows.append(Row(values: emptyRecord()))
            } label: {
                Label("Add", systemImage: "plus.circle")
            }
        }
        .buttonStyle(.borderless)
        .onAppear { syncRowsFromRecords() }
        .onChange(of: records) { _, new in
            if new != rows.map(\.values) {
                rows = new.map(Row.init(values:))
                numberDrafts.removeAll()
            }
        }
        .onChange(of: rows) { _, new in
            let mapped = new.map(\.values)
            if mapped != records { records = mapped }
        }
    }

    private func removeRow(_ id: Row.ID) {
        rows.removeAll { $0.id == id }
        numberDrafts[id] = nil
    }

    private func emptyRecord() -> [String: TypedContentEditor.FieldValue] {
        Dictionary(uniqueKeysWithValues: memberFields.map {
            ($0.name, TypedContentEditor.defaultValue(for: $0.kind))
        })
    }

    private func syncRowsFromRecords() {
        if records != rows.map(\.values) { rows = records.map(Row.init(values:)) }
    }

    @ViewBuilder
    private func memberControl(
        for field: ContentTypeField,
        in values: Binding<[String: TypedContentEditor.FieldValue]>,
        rowID: Row.ID
    ) -> some View {
        let label = field.name + (field.required ? " *" : "")
        // Exhaustive on purpose, mirroring the Mac editor: a catch-all would render the four
        // kinds a member field must not use as a working-looking control that corrupts the
        // record on save.
        switch field.kind {
        case .string, .language, .text, .url, .image:
            TextField(label, text: textBinding(field.name, in: values))
        case .bool:
            Toggle(label, isOn: flagBinding(field.name, in: values))
        case .date, .datetime:
            DatePicker(
                label, selection: dateBinding(field.name, in: values),
                displayedComponents: field.kind == .date ? [.date] : [.date, .hourAndMinute])
        case .number:
            TextField(label, text: numberBinding(field.name, in: values, rowID: rowID))
                .keyboardType(.decimalPad)
        case .markdown, .stringArray, .imageArray, .objectArray:
            Text(verbatim: "\(field.name) — unsupported member field kind")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func textBinding(
        _ name: String, in values: Binding<[String: TypedContentEditor.FieldValue]>
    ) -> Binding<String> {
        Binding(
            get: {
                if case .text(let s)? = values.wrappedValue[name] { return s }
                return ""
            },
            set: { values.wrappedValue[name] = .text($0) }
        )
    }

    private func flagBinding(
        _ name: String, in values: Binding<[String: TypedContentEditor.FieldValue]>
    ) -> Binding<Bool> {
        Binding(
            get: {
                if case .flag(let b)? = values.wrappedValue[name] { return b }
                return false
            },
            set: { values.wrappedValue[name] = .flag($0) }
        )
    }

    private func dateBinding(
        _ name: String, in values: Binding<[String: TypedContentEditor.FieldValue]>
    ) -> Binding<Date> {
        Binding(
            get: {
                if case .date(let d?)? = values.wrappedValue[name] { return d }
                return Date()
            },
            set: { values.wrappedValue[name] = .date($0) }
        )
    }

    private func numberBinding(
        _ name: String, in values: Binding<[String: TypedContentEditor.FieldValue]>,
        rowID: Row.ID
    ) -> Binding<String> {
        Binding(
            get: {
                if let draft = numberDrafts[rowID]?[name] { return draft }
                if case .number(let n?)? = values.wrappedValue[name] {
                    return ComposerNumberFormat.display(n)
                }
                return ""
            },
            set: { raw in
                numberDrafts[rowID, default: [:]][name] = raw
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    values.wrappedValue[name] = .number(nil)
                } else if let parsed = Double(trimmed) {
                    values.wrappedValue[name] = .number(parsed)
                }
            }
        )
    }
}
