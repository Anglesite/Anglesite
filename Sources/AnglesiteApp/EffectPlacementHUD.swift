import SwiftUI
import AnglesiteCore

/// The click-to-place HUD for the Effects gallery (#768): "Click where to place this effect",
/// the `inline` before/after toggle, Cancel, and the transient success/failure banner.
///
/// **Why this lives on the site window, not in `EffectsGalleryView`.** The gallery is presented as
/// a `.sheet`, and a macOS sheet is *window-modal*: it blocks input to its parent window's content
/// — which is exactly where the live preview the owner is being asked to click lives. A HUD
/// rendered inside the sheet therefore asked for a click on a surface the sheet itself was
/// blocking (#768 final review, Finding 4). "Apply to Page…" now dismisses the gallery and this
/// HUD takes over on the main window, over a genuinely clickable preview.
///
/// Rendered as a bottom-aligned `.overlay` on the site window's content, so it occupies only the
/// capsule's own bounds — everything around it stays hit-testable, and an idle HUD is an
/// `EmptyView` that takes no space at all. It stays mounted (rather than being wrapped in an `if`
/// at the call site) because it owns the transient-banner timing below.
struct EffectPlacementHUD: View {
    @Bindable var controller: EffectPlacementController

    /// Controls the transient success/failure banner: set true when `controller.state` becomes
    /// `.succeeded`/`.failed`, then cleared after a short delay so the banner fades away. Once the
    /// banner is cleared, `controller.acknowledge()` returns the controller to `.idle` — until
    /// then "Apply to Page…" stays disabled (see `EffectPlacementController`'s `.idle` guard on
    /// `startPlacement`), which is the point: no second pick can start while this one's result is
    /// still on screen.
    @State private var showTransientBanner = false

    var body: some View {
        content
            .onChange(of: controller.state) { _, newState in
                switch newState {
                case .succeeded, .failed:
                    showTransientBanner = true
                    Task {
                        try? await Task.sleep(for: .seconds(2.5))
                        showTransientBanner = false
                        controller.acknowledge()
                    }
                default:
                    showTransientBanner = false
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch controller.state {
        case .picking(let entry):
            banner(message: "Click where to place this effect", tint: .accentColor) {
                if entry.placement?.kind == .inline {
                    inlinePositionPicker
                }
                Button("Cancel") { controller.cancel() }
                    // Esc, without needing the gallery sheet (which by now is dismissed) to carry
                    // an `.onExitCommand` for it.
                    .keyboardShortcut(.cancelAction)
            }
        case .applying:
            banner(message: "Applying…", tint: .accentColor) { EmptyView() }
        case .succeeded where showTransientBanner:
            banner(message: "Effect placed.", tint: .green) { EmptyView() }
        case .failed(let message) where showTransientBanner:
            banner(message: message, tint: .red) { EmptyView() }
        default:
            EmptyView()
        }
    }

    /// Before/after choice for `inline` placements, required by the design spec §3 (the placement
    /// HUD's "small before/after toggle") — `PlacementMatcher.resolve` used to hardcode "after"
    /// with no way to say otherwise (#768 final review, Finding 6).
    private var inlinePositionPicker: some View {
        Picker("Place", selection: $controller.inlinePosition) {
            Text("Before").tag(PlacementMatcher.InlinePosition.before)
            Text("After").tag(PlacementMatcher.InlinePosition.after)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Place the effect before or after the element you click")
    }

    private func banner<Accessory: View>(
        message: String, tint: Color, @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 12) {
            Text(message)
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(tint, lineWidth: 1))
        .padding(.bottom, 24)
        .transition(.opacity)
        .animation(.default, value: showTransientBanner)
    }
}
