import SwiftUI
import AnglesiteCore
import AnglesiteBridgeCore

/// The native inspector pane for a selected WYSIWYG block's typed props (#1588 Task 7, design doc
/// §4: "system controls: steppers, color wells with the system color panel, pop-up buttons").
struct WYSIWYGInspectorView: View {
    @Bindable var model: WYSIWYGInspectorModel

    /// Tab-walks-props' landing spot (#1616) — keyed by `WYSIWYGPropDescriptor.name`, which is
    /// unique per block (it's the prop name `Op.setProp` commits against), so it doubles as a
    /// stable `@FocusState` identity without a separate index.
    @FocusState private var focusedField: String?

    var body: some View {
        Form {
            if model.descriptors.isEmpty {
                ContentUnavailableView("No editable properties", systemImage: "slider.horizontal.3")
            } else {
                ForEach(model.descriptors, id: \.name) { descriptor in
                    control(for: descriptor)
                }
            }
            licenseSection()
        }
        .formStyle(.grouped)
        // Tab/Shift-Tab from the canvas (#1616): `KeyboardNavigation` posts the request across
        // the bridge into `model.controller.inspectorFocusRequest`; landing on the first/last
        // descriptor and clearing the request back to `nil` happens here, the one place that
        // already knows the descriptor order this Form rendered. A block with no editable props
        // has nothing to focus, so the request is cleared without moving focus — the canvas keeps
        // it, same as if Tab had never been pressed.
        .onChange(of: model.controller.inspectorFocusRequest) { _, request in
            guard let request else { return }
            defer { model.controller.inspectorFocusRequest = nil }
            switch request {
            case .forward: focusedField = model.descriptors.first?.name
            case .backward: focusedField = model.descriptors.last?.name
            }
        }
        // Escape from within any prop field returns focus to the canvas (#1616) — the block stays
        // selected throughout (`focusCanvas()`'s doc comment), so there's nothing else to restore.
        .onKeyPress(.escape) {
            model.controller.focusCanvas()
            return .handled
        }
    }

    @ViewBuilder
    private func control(for descriptor: WYSIWYGPropDescriptor) -> some View {
        switch descriptor.kind {
        case .text:
            TextField(descriptor.label, text: Binding(
                get: { model.stringValue(for: descriptor.name) },
                set: { model.setString($0, for: descriptor.name) }))
                .focused($focusedField, equals: descriptor.name)
        case .number:
            Stepper(
                "\(descriptor.label): \(Int(model.numberValue(for: descriptor.name)))",
                value: Binding(
                    get: { model.numberValue(for: descriptor.name) },
                    set: { model.setNumber($0, for: descriptor.name) }))
                .focused($focusedField, equals: descriptor.name)
        case .boolean:
            Toggle(descriptor.label, isOn: Binding(
                get: { model.boolValue(for: descriptor.name) },
                set: { model.setBool($0, for: descriptor.name) }))
                .focused($focusedField, equals: descriptor.name)
        case .color:
            colorControl(for: descriptor)
        case .enumeration:
            Picker(descriptor.label, selection: Binding(
                get: { model.stringValue(for: descriptor.name) },
                set: { model.setString($0, for: descriptor.name) })
            ) {
                ForEach(descriptor.enumOptions, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .focused($focusedField, equals: descriptor.name)
        }
    }

    /// Mirrors `ComponentStyleInspectorPane`'s ColorPicker-over-hex-text pattern
    /// (`ComponentStyleInspectorPane.swift:171-187`): the text field always works, and a
    /// `ColorPicker` (system color well) appears alongside it once the current value parses as a
    /// hex color. The leading `TextField` carries this descriptor's `@FocusState` identity — it's
    /// always present (the `ColorPicker` only shows once the value parses), so it's the one
    /// reachable landing spot for a Tab request onto a color prop.
    private func colorControl(for descriptor: WYSIWYGPropDescriptor) -> some View {
        let stringBinding = Binding(
            get: { model.stringValue(for: descriptor.name) },
            set: { model.setString($0, for: descriptor.name) })
        return HStack {
            TextField(descriptor.label, text: stringBinding)
                .focused($focusedField, equals: descriptor.name)
            if let color = CSSColor.parse(stringBinding.wrappedValue) {
                ColorPicker("", selection: Binding(
                    get: { color },
                    set: { stringBinding.wrappedValue = CSSColor.format($0) }))
                .labelsHidden()
            }
        }
    }

    /// The embedded-license section (#1672) — shown only when `model.licenseSectionState` is
    /// non-nil (an `img` block whose page doesn't suppress file-level licensing). The picker
    /// offers catalog licenses only, matching `InsertImageLicenseChoice` (resolved default 5:
    /// clearing to "none" is out of scope here).
    @ViewBuilder
    private func licenseSection() -> some View {
        if let state = model.licenseSectionState {
            Section("License") {
                switch state {
                case .disabled(let reason):
                    Text(reason)
                        .foregroundStyle(.secondary)
                case .unsupportedFormat:
                    Text("This file format doesn't support an embedded license.")
                        .foregroundStyle(.secondary)
                case .editable(let current, _, _):
                    if let current {
                        Text(current.name)
                    } else {
                        Text("No license embedded")
                            .foregroundStyle(.secondary)
                    }
                    Picker("Change to", selection: Binding(
                        get: { LicenseCatalog.entry(for: current)?.id ?? LicenseCatalog.entries[0].id },
                        set: { id in
                            guard let entry = LicenseCatalog.entries.first(where: { $0.id == id }) else { return }
                            model.setEmbeddedLicense(entry.ref)
                        })
                    ) {
                        ForEach(LicenseCatalog.entries) { entry in
                            Text(entry.name).tag(entry.id)
                        }
                    }
                }
            }
        }
    }
}
