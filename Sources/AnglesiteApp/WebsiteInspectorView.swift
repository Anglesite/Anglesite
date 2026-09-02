import SwiftUI
import AnglesiteCore

/// The Website inspector panel (#714 v2 slice 1): title, language, domain, and stylesheets
/// for the current site. Mirrored at the top of the window alongside the main editor (#1056).
struct WebsiteInspectorView: View {
    @Bindable var model: WebsiteInspectorModel
    let openStylesheet: (FileRef) -> Void
    let openMoreSettings: () -> Void

    /// Hoisted to `SiteWindow` (#1699 slice 1) — same `NSHostingController`/scene-storage
    /// constraint as `SiteInspectorView.tab`.
    @Binding var tab: SiteInspectorTab
    @FocusState private var titleFocused: Bool
    @FocusState private var languageFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector Tab", selection: $tab) {
                Text("Metadata").tag(SiteInspectorTab.metadata)
                Text("Style").tag(SiteInspectorTab.style)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            content
        }
        .onChange(of: titleFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                Task { await model.saveTitle() }
            }
        }
        .onChange(of: languageFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                Task { await model.saveLang() }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .metadata:
            Form {
                TextField("Title", text: $model.title)
                    .focused($titleFocused)
                    .onSubmit { Task { await model.saveTitle() } }
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Language", text: $model.lang)
                        .focused($languageFocused)
                        .onSubmit { Task { await model.saveLang() } }
                    Text("A BCP 47 language tag, e.g. \"en\", \"fr-CA\", \"es\". Screen readers and search engines use this to pronounce and index your content correctly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Domain", value: model.domain ?? "Not configured")
                if let saveError = model.saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
                Section {
                    Button("More Settings…") { openMoreSettings() }
                }
            }
            .formStyle(.grouped)
        case .style:
            List(model.stylesheets) { sheet in
                Button { openStylesheet(sheet) } label: {
                    Label(sheet.name, systemImage: "doc.text")
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if model.stylesheets.isEmpty {
                    ContentUnavailableView("No stylesheets", systemImage: "paintbrush")
                }
            }
        }
    }
}
