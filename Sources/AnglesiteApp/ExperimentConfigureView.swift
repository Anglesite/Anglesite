import SwiftUI
import AnglesiteCore

/// The configure step of the experiment lifecycle (#1518): scaffold the variant page, choose
/// what counts as a win, then start the test. Reached from `.propose` once a `Draft` exists;
/// `model.step`'s associated `Draft` is the single source of truth for what's already set.
struct ExperimentConfigureView: View {
    @Bindable var model: ExperimentStatsModel
    /// Runs the site's one real deploy path — `SiteWindowModel.deploySite()`, threaded down from
    /// `SiteWindow`. Deliberately not a `DeployModel.deploy(...)` call assembled here: only
    /// `SiteWindowModel` can enumerate the site's full route set and its `Config/` directory, and
    /// getting either wrong corrupts the deployed-routes snapshot or the worker plan (#1518 C2).
    var deploySite: () -> Void
    /// Owner-facing reason `deploySite` would not actually publish right now, or `nil`. Evaluated
    /// at `SiteWindow`, where both `SiteWindowModel.canRunDeploy` and `DeployModel`'s own
    /// preconditions are visible — see `ExperimentStatsModel.start(unavailableReason:deploy:)`.
    var deployUnavailableReason: () -> String?
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
                        if let reason = model.scaffoldFailureReason {
                            Text(reason).font(.caption).foregroundStyle(.orange)
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
                        HStack {
                            Button(model.goalPickController.state == .picking ? "Click the element in the preview…" : "Choose in the preview") {
                                model.goalPickController.startPicking(enterOverlayMode: enterGoalPickMode, exitOverlayMode: exitGoalPickMode)
                            }
                            .disabled(model.goalPickController.state == .picking)
                            // Without this (and the sheet's `.onExitCommand`), picking mode has no
                            // exit: the preview overlay stays armed and the button stays disabled
                            // for the rest of the sheet's life (#1518 review, I1). Mirrors
                            // `EffectsGalleryView`'s placement-HUD Cancel.
                            if model.goalPickController.state == .picking {
                                Button("Cancel") { model.goalPickController.cancel() }
                            }
                        }
                        if case .failed(let reason) = model.goalPickController.state {
                            Text(reason).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Section {
                    Button("Start your test") {
                        model.start(unavailableReason: deployUnavailableReason(), deploy: deploySite)
                    }
                    .disabled(!model.canStart)
                    if let reason = model.startFailureReason {
                        Text(reason).font(.caption).foregroundStyle(.orange)
                    }
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
