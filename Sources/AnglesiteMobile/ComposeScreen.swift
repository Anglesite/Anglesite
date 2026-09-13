// Sources/AnglesiteMobile/ComposeScreen.swift
import SwiftUI
import UIKit
import PhotosUI
import AnglesiteIOS
import AnglesiteCore
import AnglesiteMobileCore

/// The composer (#869): a registry-driven typed form over one post, with the Markdown body
/// surface and the Save Draft / Publish actions. All state lives in `PostComposerModel`
/// (`AnglesiteIOS`); this screen renders its phase and forwards intents. The phase predicates,
/// field layout, upload-failure classification, and network wait it leans on are
/// `AnglesiteMobileCore` (tested under `swift test`, #1968) — only rendering and copy live here.
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
                        .disabled(model.phase.isSending)
                    Button("Publish") { Task { await model.publish(); notifyIfSent() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.phase.isSending)
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
            .task(id: model.phase.isWaitingForNetwork) {
                // The waiting-for-network state's automatic retry trigger while the app is
                // running; `NetworkWait` honors the cancellation SwiftUI issues when the
                // composer goes away, and the re-check below keeps a cancel-resume from retrying.
                guard model.phase.isWaitingForNetwork else { return }
                await NetworkWait.untilSatisfied()
                guard !Task.isCancelled else { return }
                await model.retry()
                notifyIfSent()
            }
    }

    private var conflictPresented: Binding<Bool> {
        Binding(
            get: { model.phase.isConflict },
            set: { presented in
                // Dismissing without choosing keeps editing; the conflict re-arms on next send.
                if !presented, model.phase.isConflict { model.resumeEditing() }
            }
        )
    }

    private func notifyIfSent() {
        if model.phase.didSend { onSent() }
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
            ForEach(ComposerFieldLayout.scalarFields(of: model.descriptor), id: \.name) { field in
                control(for: field)
            }
            if let body = ComposerFieldLayout.bodyField(of: model.descriptor) {
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
        case .enum(let cases):
            Picker(label, selection: model.textBinding(field.name)) {
                ForEach(cases, id: \.self) { Text($0) }
            }
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
            data: data, filename: url.lastPathComponent,
            mimeType: MediaUploadPresentation.mimeType(forFileExtension: url.pathExtension))
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

    /// Owner-facing copy per `MediaUploadPresentation.classify` case — the classification is
    /// tested in `AnglesiteMobileCore`; the literals stay here for String Catalog extraction.
    private static func describe(_ error: PostComposerModel.MediaUploadError) -> String {
        switch MediaUploadPresentation.classify(error) {
        case .tooLarge(let size):
            return String(localized: "That image is \(size) — the limit is 25 MB.")
        case .unsupportedFormat(let mimeType):
            return String(localized: "\(mimeType) images can't be shown on the web.")
        case .empty:
            return String(localized: "That file is empty.")
        case .reauthorizationRequired:
            return String(localized: "Your site needs you to sign in again.")
        case .transportFailed:
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
        ObjectRecordFields.emptyRecord(memberFields: memberFields)
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
        case .markdown, .stringArray, .imageArray, .objectArray, .enum:
            Text(verbatim: "\(field.name) — unsupported member field kind")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // The value rules behind these bindings are `ObjectRecordFields` (AnglesiteMobileCore);
    // only the SwiftUI `Binding` wrapping lives here.

    private func textBinding(
        _ name: String, in values: Binding<[String: TypedContentEditor.FieldValue]>
    ) -> Binding<String> {
        Binding(
            get: { ObjectRecordFields.text(name, in: values.wrappedValue) },
            set: { values.wrappedValue[name] = .text($0) }
        )
    }

    private func flagBinding(
        _ name: String, in values: Binding<[String: TypedContentEditor.FieldValue]>
    ) -> Binding<Bool> {
        Binding(
            get: { ObjectRecordFields.flag(name, in: values.wrappedValue) },
            set: { values.wrappedValue[name] = .flag($0) }
        )
    }

    private func dateBinding(
        _ name: String, in values: Binding<[String: TypedContentEditor.FieldValue]>
    ) -> Binding<Date> {
        Binding(
            get: { ObjectRecordFields.date(name, in: values.wrappedValue) ?? Date() },
            set: { values.wrappedValue[name] = .date($0) }
        )
    }

    private func numberBinding(
        _ name: String, in values: Binding<[String: TypedContentEditor.FieldValue]>,
        rowID: Row.ID
    ) -> Binding<String> {
        Binding(
            get: {
                ObjectRecordFields.numberText(name, in: values.wrappedValue, draft: numberDrafts[rowID]?[name])
            },
            set: { raw in
                numberDrafts[rowID, default: [:]][name] = raw
                if let value = ObjectRecordFields.parsedNumber(from: raw) {
                    values.wrappedValue[name] = value
                }
            }
        )
    }
}
