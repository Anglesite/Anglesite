import AppKit
import AnglesiteCore

/// A real `NSMenu` for a right-clicked block, built from the engine's hit-test result — never a
/// web context menu (spec §8.1: "the engine hit-tests and reports the block under the cursor; the
/// host builds the menu"). Follows the target/action + `representedObject` convention already used
/// for the app's Dock menu (`AnglesiteApp.swift`'s `applicationDockMenu`), the only prior native
/// `NSMenu` construction in this codebase.
@MainActor
enum WYSIWYGBlockContextMenu {
    /// Boxes the controller + block id together as the `representedObject` every item shares,
    /// since `NSMenuItem.representedObject` takes a single `Any`.
    private final class Context {
        let controller: WYSIWYGCanvasController
        let blockId: BlockId
        init(controller: WYSIWYGCanvasController, blockId: BlockId) {
            self.controller = controller
            self.blockId = blockId
        }
    }

    static func build(for blockId: BlockId, controller: WYSIWYGCanvasController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let context = Context(controller: controller, blockId: blockId)
        let target = Target()

        let duplicate = NSMenuItem(title: "Duplicate", action: #selector(Target.duplicate(_:)), keyEquivalent: "")
        duplicate.target = target
        duplicate.representedObject = context
        menu.addItem(duplicate)

        let delete = NSMenuItem(title: "Delete", action: #selector(Target.delete(_:)), keyEquivalent: "")
        delete.target = target
        delete.representedObject = context
        menu.addItem(delete)

        // `target` (an NSObject, needed for #selector/Objective-C dispatch) must outlive the
        // menu's lifetime on screen — stash it as an associated object on the menu itself so it
        // isn't deallocated the instant `build` returns.
        objc_setAssociatedObject(menu, &targetAssociationKey, target, .OBJC_ASSOCIATION_RETAIN)
        return menu
    }

    @MainActor
    private final class Target: NSObject {
        @objc func duplicate(_ sender: NSMenuItem) {
            guard let context = sender.representedObject as? Context else { return }
            context.controller.selectedBlockId = context.blockId
            Task { await context.controller.duplicateSelectedBlock() }
        }

        @objc func delete(_ sender: NSMenuItem) {
            guard let context = sender.representedObject as? Context else { return }
            context.controller.selectedBlockId = context.blockId
            Task { await context.controller.deleteSelectedBlock() }
        }
    }
}

private nonisolated(unsafe) var targetAssociationKey: UInt8 = 0
