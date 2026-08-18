import SwiftUI
import AnglesiteCore

/// The configure step of the experiment lifecycle (#1518): scaffold the variant page, choose
/// what counts as a win, then start the test. Reached from `.propose` once a `Draft` exists;
/// `model.step`'s associated `Draft` is the single source of truth for what's already set.
struct ExperimentConfigureView: View {
    @Bindable var model: ExperimentStatsModel
    var enterGoalPickMode: () -> Void
    var exitGoalPickMode: () -> Void

    @State private var scrollDepth: Double = 75
    @State private var pageviewPath: String = ""

    private var draft: ExperimentStatsModel.Draft? {
        guard case .configure(let draft) = model.step else { return nil }
        return draft
    }

    var body: some View {
        Form {
            if let draft {
                Section(draft.name) {
                    if draft.variantPage == nil {
                        Button("Create the variant page") {
                            Task { await model.scaffoldVariant() }
                        }
                    } else {
                        LabeledContent("Variant page", value: draft.variantPage ?? "")
                        Text("Edit its content from the page editor, then choose what counts as a win below.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("What counts as a win?") {
                    goalOptionRow(
                        title: "Counts when a visitor reaches a page",
                        isSelected: draft.goalKind == "pageview") {
                        TextField("Page (e.g. /contact/thanks/)", text: $pageviewPath)
                        Button("Use this page") { model.setPageviewGoal(path: pageviewPath) }
                            .disabled(pageviewPath.isEmpty)
                    }
                    goalOptionRow(
                        title: "Counts when a visitor scrolls partway down",
                        isSelected: draft.goalKind == "scroll") {
                        Slider(value: $scrollDepth, in: 1...100, step: 1) {
                            Text("Scroll depth")
                        }
                        Button("Use \(Int(scrollDepth))% scrolled") { model.setScrollGoal(depth: Int(scrollDepth)) }
                    }
                    goalOptionRow(
                        title: "Counts when a visitor sees something on the page",
                        isSelected: draft.goalKind == "visible") {
                        Button(model.goalPickController.state == .picking ? "Click the element in the preview…" : "Choose in the preview") {
                            model.goalPickController.startPicking(enterOverlayMode: enterGoalPickMode, exitOverlayMode: exitGoalPickMode)
                        }
                        .disabled(model.goalPickController.state == .picking)
                        if case .failed(let reason) = model.goalPickController.state {
                            Text(reason).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Section {
                    Button("Start your test") {
                        model.start(deploy: { _, _, _, _ in }) // Task 15 supplies the real deploy call
                    }
                    .disabled(!model.canStart)
                }
            }
        }
    }

    // Not a `Button`-per-row like `LicenseGateSheetView`'s comparison table: each row's actual
    // controls (a `TextField`+button, a `Slider`+button, or a picker-launching button) must stay
    // independently focusable and tappable, and SwiftUI doesn't support nested interactive
    // controls inside an outer `Button`. Instead, the identifying title+icon is grouped into a
    // single combined accessibility element carrying the `.isSelected` state — so VoiceOver
    // reaches one clearly identified "selected"/"not selected" landmark per option, distinct from
    // (and before) the real controls underneath it that remain separately reachable.
    @ViewBuilder
    private func goalOptionRow<Content: View>(title: String, isSelected: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading) {
            Label(title, systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            content()
        }
    }
}
