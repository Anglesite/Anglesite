// Sources/AnglesiteApp/ProjectStyleGuideView.swift
import SwiftUI
import AnglesiteCore

/// Sheet showing the site's learned `ProjectConventions`, sectioned by category, with an
/// edit/override affordance per learnable field. Frontmatter is read-only (ground truth from
/// `content.config.ts`, not inference — see `FrontmatterSchemaReader`).
struct ProjectStyleGuideView: View {
    let model: ProjectConventionsModel
    let siteName: String

    @Environment(\.dismiss) private var dismiss
    @State private var interviewPresented = false

    var body: some View {
        NavigationStack {
            Group {
                if let conventions = model.conventions {
                    List {
                        writingSection(conventions)
                        imagesSection(conventions)
                        componentsSection(conventions)
                        namingSection(conventions)
                        seoSection(conventions)
                        frontmatterSection(conventions)
                    }
                } else {
                    ProgressView("Learning \(siteName)’s conventions…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Project Style Guide")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Set Up Brand Voice…") { interviewPresented = true }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Rescan Now") {
                        Task { await model.rescan() }
                    }
                    .disabled(model.isLearning)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .sheet(isPresented: $interviewPresented) {
            BrandVoiceInterviewView(model: model)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func writingSection(_ conventions: ProjectConventions) -> some View {
        Section("Writing") {
            PickerConventionRow(
                label: "Heading style",
                learned: conventions.writing.headingCapitalization,
                onSet: { value in Task { await model.setOverride(.headingCapitalization(value)) } },
                onClear: { Task { await model.clearOverride(.headingCapitalization) } }
            )
            TokenListConventionRow(
                label: "Tone",
                placeholder: "Not learned yet",
                learned: conventions.writing.toneDescriptors,
                onSet: { value in Task { await model.setOverride(.toneDescriptors(value)) } },
                onClear: { Task { await model.clearOverride(.toneDescriptors) } }
            )
            TokenListConventionRow(
                label: "Brand terms",
                placeholder: "Not learned yet",
                learned: conventions.writing.brandTerms,
                onSet: { value in Task { await model.setOverride(.brandTerms(value)) } },
                onClear: { Task { await model.clearOverride(.brandTerms) } }
            )
        }
    }

    @ViewBuilder
    private func imagesSection(_ conventions: ProjectConventions) -> some View {
        Section("Images") {
            NumberConventionRow(
                label: "Average alt text length",
                suffix: "characters",
                learned: conventions.images.altTextAverageLength,
                onSet: { value in Task { await model.setOverride(.altTextAverageLength(value)) } },
                onClear: { Task { await model.clearOverride(.altTextAverageLength) } }
            )
            ToggleConventionRow(
                label: "Ends with punctuation",
                learned: conventions.images.altTextEndsWithPunctuation,
                onSet: { value in Task { await model.setOverride(.altTextEndsWithPunctuation(value)) } },
                onClear: { Task { await model.clearOverride(.altTextEndsWithPunctuation) } }
            )
        }
    }

    @ViewBuilder
    private func componentsSection(_ conventions: ProjectConventions) -> some View {
        Section("Components") {
            if conventions.components.usageCounts.value.isEmpty {
                Text("No component usage learned yet.").foregroundStyle(.secondary)
            } else {
                ForEach(conventions.components.usageCounts.value.sorted(by: { $0.value > $1.value }), id: \.key) { name, count in
                    LabeledContent(name) { Text("\(count)") }
                }
            }
        }
    }

    @ViewBuilder
    private func namingSection(_ conventions: ProjectConventions) -> some View {
        Section("Naming") {
            PickerConventionRow(
                label: "Slug style",
                learned: conventions.naming.slugStyle,
                onSet: { value in Task { await model.setOverride(.slugStyle(value)) } },
                onClear: { Task { await model.clearOverride(.slugStyle) } }
            )
        }
    }

    @ViewBuilder
    private func seoSection(_ conventions: ProjectConventions) -> some View {
        Section("SEO") {
            NumberConventionRow(
                label: "Average meta description length",
                suffix: "characters",
                learned: conventions.seo.metaDescriptionAverageLength,
                onSet: { value in Task { await model.setOverride(.metaDescriptionAverageLength(value)) } },
                onClear: { Task { await model.clearOverride(.metaDescriptionAverageLength) } }
            )
        }
    }

    @ViewBuilder
    private func frontmatterSection(_ conventions: ProjectConventions) -> some View {
        Section("Frontmatter (read from content.config.ts)") {
            if conventions.frontmatter.collections.isEmpty {
                Text("No content collections found.").foregroundStyle(.secondary)
            } else {
                ForEach(conventions.frontmatter.collections.keys.sorted(), id: \.self) { name in
                    LabeledContent(name) {
                        Text((conventions.frontmatter.collections[name] ?? []).joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Row status (shared by every editable row type)

    /// Shared trailing status indicator: "edited" + Revert when the field is a `.userOverride`,
    /// or a "low confidence" note when it's inferred from very few files.
    @ViewBuilder
    fileprivate static func statusIndicator<Value>(_ learned: Learned<Value>, onClear: @escaping () -> Void) -> some View {
        if learned.isOverridden {
            Text("edited").font(.caption2).foregroundStyle(.secondary)
            Button("Revert", action: onClear).font(.caption2)
        } else if let sampleSize = learned.sampleSize, sampleSize > 0, sampleSize < 3 {
            Text("low confidence").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Editable row types

/// A row for an enum-valued `Learned` field, editable via a menu `Picker` over every case.
/// Selecting a value calls `onSet` immediately — a menu choice is a discrete action, not
/// per-keystroke typing, so there's no need to buffer/debounce it.
private struct PickerConventionRow<Option: Hashable & CaseIterable & RawRepresentable & Sendable & Codable>: View
where Option.RawValue == String, Option.AllCases: RandomAccessCollection {
    let label: String
    let learned: Learned<Option>
    let onSet: (Option) -> Void
    let onClear: () -> Void

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Picker("", selection: Binding(get: { learned.value }, set: onSet)) {
                    ForEach(Array(Option.allCases), id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                ProjectStyleGuideView.statusIndicator(learned, onClear: onClear)
            }
        }
    }
}

/// A row for a `Bool`-valued `Learned` field, editable via a `Toggle`. Fires `onSet` immediately
/// on flip — a toggle is a discrete action, same reasoning as the picker row.
private struct ToggleConventionRow: View {
    let label: String
    let learned: Learned<Bool>
    let onSet: (Bool) -> Void
    let onClear: () -> Void

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Toggle("", isOn: Binding(get: { learned.value }, set: onSet)).labelsHidden()
                    .accessibilityLabel(label)
                ProjectStyleGuideView.statusIndicator(learned, onClear: onClear)
            }
        }
    }
}

/// A row for an `Int`-valued `Learned` field (a character-count length), editable via a numeric
/// `TextField`. Buffers typed text locally in `text` and commits to `onSet` only on Return or
/// focus loss — never per keystroke. Reverts the buffer to the last known value on invalid or
/// unchanged input so a bad edit can't silently corrupt the model.
private struct NumberConventionRow: View {
    let label: String
    let suffix: String
    let learned: Learned<Int>
    let onSet: (Int) -> Void
    let onClear: () -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("", text: $text)
                    .accessibilityLabel(label)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                    .focused($isFocused)
                    .onAppear { text = String(learned.value) }
                    .onChange(of: learned.value) { _, newValue in
                        if !isFocused { text = String(newValue) }
                    }
                    .onSubmit { commit() }
                    .onChange(of: isFocused) { wasFocused, nowFocused in
                        if wasFocused, !nowFocused { commit() }
                    }
                Text(suffix).foregroundStyle(.secondary)
                ProjectStyleGuideView.statusIndicator(learned, onClear: onClear)
            }
        }
    }

    private func commit() {
        guard let value = Int(text), value >= 0, value != learned.value else {
            text = String(learned.value)
            return
        }
        onSet(value)
    }
}

/// A row for a `[String]`-valued `Learned` field (tone descriptors, brand terms), editable as a
/// comma-separated `TextField`. Same buffer/commit discipline as `NumberConventionRow`.
private struct TokenListConventionRow: View {
    let label: String
    let placeholder: String
    let learned: Learned<[String]>
    let onSet: ([String]) -> Void
    let onClear: () -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onAppear { text = learned.value.joined(separator: ", ") }
                    .onChange(of: learned.value) { _, newValue in
                        if !isFocused { text = newValue.joined(separator: ", ") }
                    }
                    .onSubmit { commit() }
                    .onChange(of: isFocused) { wasFocused, nowFocused in
                        if wasFocused, !nowFocused { commit() }
                    }
                ProjectStyleGuideView.statusIndicator(learned, onClear: onClear)
            }
        }
    }

    private func commit() {
        let parsed = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parsed != learned.value else { return }
        onSet(parsed)
    }
}
