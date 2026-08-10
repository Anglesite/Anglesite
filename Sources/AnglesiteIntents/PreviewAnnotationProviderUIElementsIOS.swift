// UIKit-only half of `PreviewAnnotationProvider` (mirrors B.4 / #148 for iOS, tracked on #1386):
// the `AppEntityUIElement` surface comes from the `_AppIntents_UIKit` cross-import overlay, so
// this file is iOS-only. The macOS equivalent lives in `PreviewAnnotationProviderUIElements.swift`
// — same shape, `AppKit` swapped for `UIKit`. Keeping them as separate files (rather than one
// file with a platform-conditional import) matches that file's existing split and keeps each
// half greppable by the framework it depends on.
#if os(iOS)
import AppIntents
import UIKit
import CoreGraphics
import Foundation

// `AppEntityUIElement` and `AppEntityUIElementsContext` are defined by the `_AppIntents_UIKit`
// cross-import overlay, which auto-loads when both `AppIntents` and `UIKit` are imported
// explicitly in the consuming file. Swift's `MemberImportVisibility` upcoming-feature (enabled
// by the iOS 27 SDK module flags) requires both base modules here — transitive imports through
// other frameworks aren't enough, and the compile error blames the type rather than the missing
// import. See `PreviewAnnotationProviderUIElements.swift` for the macOS/AppKit precedent this
// mirrors line-for-line.
#if compiler(>=6.4)
extension PreviewAnnotationProvider {
    /// Shape annotations into `[AppEntityUIElement]` for `WKWebView.appEntityUIElementProvider`
    /// on iOS. The system asks for either `.visible(rect:)` — return everything whose stored
    /// rect intersects `rect` — or `.selected`. We don't track an in-page selection model (the
    /// overlay's hover/click states are transient), so `.selected` yields `[]`.
    public func uiElements(for context: AppEntityUIElementsContext) -> [AppEntityUIElement] {
        uiElements(forRequests: context.requests)
    }

    /// Inner helper taking the raw request set so tests can drive it directly —
    /// `AppEntityUIElementsContext` has no public initializer.
    public func uiElements(
        forRequests requests: Set<AppEntityUIElementsContext.ElementsRequest>
    ) -> [AppEntityUIElement] {
        var out: [AppEntityUIElement] = []
        for request in requests {
            switch request {
            case .visible(let rect):
                for (annoRect, entity) in annotations() where annoRect.intersects(rect) {
                    out.append(makeUIElement(entity: entity, bounds: annoRect))
                }
            case .selected:
                continue
            @unknown default:
                continue
            }
        }
        return out
    }

    /// Existential-opening helper. `AppEntityUIElement.init<E: AppEntity>(_ entity:, bounds:)` is
    /// generic over a concrete entity type; each of the four concrete types we map to gets a
    /// dedicated branch so the compiler can specialize. The trailing fallback exists only to
    /// satisfy the type checker — the four cases above are exhaustive given `resolve`'s rules.
    /// If a fifth entity type is ever returned by `resolve` without updating this switch, the
    /// `assertionFailure` makes the regression loud in debug builds; release builds fall through
    /// to the placeholder so production keeps working.
    private func makeUIElement(entity: any AppEntity, bounds: CGRect) -> AppEntityUIElement {
        if let e = entity as? PageEntity { return AppEntityUIElement(e, bounds: bounds) }
        if let e = entity as? PostEntity { return AppEntityUIElement(e, bounds: bounds) }
        if let e = entity as? ImageEntity { return AppEntityUIElement(e, bounds: bounds) }
        if let e = entity as? ElementEntity { return AppEntityUIElement(e, bounds: bounds) }
        assertionFailure("makeUIElement: unhandled entity type \(type(of: entity)) — extend the switch in PreviewAnnotationProvider")
        let placeholder = ElementEntity(
            id: "unknown", displayName: "unknown", siteID: siteID,
            selector: "{}", pagePath: "/"
        )
        return AppEntityUIElement(placeholder, bounds: bounds)
    }
}
#endif
#endif
