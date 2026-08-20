import SwiftUI
import AnglesiteCore

/// The native inspector pane for a selected WYSIWYG block's typed props (#1588 Task 7, design doc
/// §4: "system controls: steppers, color wells with the system color panel, pop-up buttons").
struct WYSIWYGInspectorView: View {
    @Bindable var model: WYSIWYGInspectorModel

    var body: some View {
        Form {
            if model.descriptors.isEmpty {
                ContentUnavailableView("No editable properties", systemImage: "slider.horizontal.3")
            } else {
                ForEach(model.descriptors, id: \.name) { descriptor in
                    control(for: descriptor)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func control(for descriptor: WYSIWYGPropDescriptor) -> some View {
        switch descriptor.kind {
        case .text:
            TextField(descriptor.label, text: Binding(
                get: { model.stringValue(for: descriptor.name) },
                set: { model.setString($0, for: descriptor.name) }))
        case .number:
            Stepper(
                "\(descriptor.label): \(Int(model.numberValue(for: descriptor.name)))",
                value: Binding(
                    get: { model.numberValue(for: descriptor.name) },
                    set: { model.setNumber($0, for: descriptor.name) }))
        case .boolean:
            Toggle(descriptor.label, isOn: Binding(
                get: { model.boolValue(for: descriptor.name) },
                set: { model.setBool($0, for: descriptor.name) }))
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
        }
    }

    /// Mirrors `ComponentStyleInspectorPane`'s ColorPicker-over-hex-text pattern
    /// (`ComponentStyleInspectorPane.swift:171-187`): the text field always works, and a
    /// `ColorPicker` (system color well) appears alongside it once the current value parses as a
    /// hex color.
    private func colorControl(for descriptor: WYSIWYGPropDescriptor) -> some View {
        let stringBinding = Binding(
            get: { model.stringValue(for: descriptor.name) },
            set: { model.setString($0, for: descriptor.name) })
        return HStack {
            TextField(descriptor.label, text: stringBinding)
            if let color = CSSColor.parse(stringBinding.wrappedValue) {
                ColorPicker("", selection: Binding(
                    get: { color },
                    set: { stringBinding.wrappedValue = CSSColor.format($0) }))
                .labelsHidden()
            }
        }
    }
}
