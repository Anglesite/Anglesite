import SwiftUI

/// Honest-labeling caption for #800/#801's V-3 conformance gate — shown, never blocking, under
/// sign-in/connect UI whenever there's an advisory to show (`advisory` non-`nil`; renders nothing
/// otherwise). Shared between the Mac connect sheet (`AnglesiteApp`) and iOS sign-in screen
/// (`AnglesiteMobile`) so the two platforms' wording and styling can't drift apart — see
/// `WorkerActivation.micropubConformanceAdvisory`'s doc comment for why this labels rather than
/// hides the surface.
public struct ConformanceAdvisoryLabel: View {
    private let advisory: String?

    public init(advisory: String?) {
        self.advisory = advisory
    }

    public var body: some View {
        if let advisory {
            Text(advisory)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }
}
