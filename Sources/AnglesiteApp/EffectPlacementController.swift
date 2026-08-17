// Sources/AnglesiteApp/EffectPlacementController.swift
import Foundation
import Observation
import AnglesiteCore

/// Drives the click-to-place flow for one effect: enters overlay placement-pick mode, waits for
/// a click, resolves it against a freshly-fetched `PageModel` via `PlacementMatcher`, and applies
/// the resulting `insertBlock` edit. One instance per site window (constructed alongside
/// `PageModelClient`/`editRouter` in `SiteWindowModel`, Task 12); `startPlacement`/`cancel` are
/// idempotent no-ops when called out of turn (e.g. a stray double-click).
@MainActor
@Observable
public final class EffectPlacementController {
    public enum State: Equatable {
        case idle
        case picking(entry: EffectCatalogEntry)
        case applying
        case succeeded
        case failed(String)
    }

    public private(set) var state: State = .idle

    private let path: String
    private let pageModelClient: PageModelClient
    private let editRouter: any EditRouter
    private var exitOverlayMode: (() -> Void)?

    public init(path: String, pageModelClient: PageModelClient, editRouter: any EditRouter) {
        self.path = path
        self.pageModelClient = pageModelClient
        self.editRouter = editRouter
    }

    /// Enters placement-pick mode for `entry`. `enterOverlayMode`/`exitOverlayMode` are the
    /// caller's bridge into the live preview's `window.anglesite._enterPlacementMode()` /
    /// `_exitPlacementMode()` (Task 9) — kept as closures so this type has no WKWebView
    /// dependency and stays unit-testable.
    public func startPlacement(for entry: EffectCatalogEntry, enterOverlayMode: @escaping () -> Void, exitOverlayMode: @escaping () -> Void) {
        guard case .idle = state else { return }
        self.exitOverlayMode = exitOverlayMode
        state = .picking(entry: entry)
        enterOverlayMode()
    }

    /// Cancels an in-progress pick (Esc / Cancel button), exiting overlay mode and returning to
    /// `.idle`. A no-op if nothing is in progress.
    public func cancel() {
        guard case .picking = state else { return }
        exitOverlayMode?()
        exitOverlayMode = nil
        state = .idle
    }

    /// Handles a reported placement click: fetches the current page model, matches the click,
    /// builds and applies the `insertBlock` edit. Always exits overlay mode on return, success
    /// or failure — a picking session is one click.
    public func handlePick(_ message: PlacementPickMessage) async {
        guard case .picking(let entry) = state, let placement = entry.placement else { return }
        exitOverlayMode?()
        exitOverlayMode = nil
        state = .applying

        do {
            let model = try await pageModelClient.fetch(path: path)
            switch PlacementMatcher.resolve(element: message.element, in: model, placement: placement) {
            case .success(let insertion):
                let edit = ComponentStructureEditBuilder.insertBlock(
                    id: UUID().uuidString, path: path, baseVersion: model.version,
                    parentId: insertion.parentId, index: insertion.index, manifestBlock: entry.title)
                let reply = await editRouter.apply(edit)
                switch reply.status {
                case .applied:
                    state = .succeeded
                case .failed, .ambiguous, .preview:
                    state = .failed(reply.message ?? "The edit was refused.")
                }
            case .failure(.noMatch):
                state = .failed("Couldn't find that spot on the page — try clicking a different element.")
            case .failure(.ambiguous):
                state = .failed("That spot matched more than one place on the page — try a more specific element.")
            }
        } catch let error as PageModelClient.ModelError {
            state = .failed(error.friendlyMessage)
        } catch {
            state = .failed(String(describing: error))
        }
    }
}
