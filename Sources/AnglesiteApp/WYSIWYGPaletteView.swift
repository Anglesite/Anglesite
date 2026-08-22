import SwiftUI
import UniformTypeIdentifiers
import AnglesiteCore

extension UTType {
    /// App-internal only (no Info.plist export needed) — this payload never leaves the app's own
    /// drag sessions, so a dynamic UTType is sufficient, same posture `ComponentOutline.swift`'s
    /// `OutlineDragPayload` Transferable already takes for the Component Editor's own in-app drags.
    static let wysiwygBlockPaletteEntry = UTType(exportedAs: "io.dwk.anglesite.wysiwyg-block-palette-entry")
}

/// What a palette row exports when dragged into the canvas (Task 11 reads this on drop) — just
/// enough to build a fresh `BlockNodeContent`, not the whole `WYSIWYGBlockPaletteEntry` (whose
/// `id`/`props` schema the drop target doesn't need to carry across the drag).
struct WYSIWYGPaletteDragPayload: Codable, Transferable {
    let kind: BlockKind
    let componentName: String
    let displayName: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .wysiwygBlockPaletteEntry)
    }
}

/// The native block palette (#1588 Task 9, design doc §4: "native source list"). Double-clicking a
/// row inserts at the page root (same as `InsertCommands`'s menu items); dragging a row into the
/// canvas is wired in Task 11.
struct WYSIWYGPaletteView: View {
    let entries: [WYSIWYGBlockPaletteEntry]
    let onInsert: (WYSIWYGBlockPaletteEntry) -> Void

    var body: some View {
        List(entries) { entry in
            Label(entry.displayName, systemImage: Self.icon(for: entry.kind))
                .draggable(WYSIWYGPaletteDragPayload(kind: entry.kind, componentName: entry.componentName, displayName: entry.displayName))
                .onTapGesture(count: 2) { onInsert(entry) }
        }
        .listStyle(.sidebar)
    }

    private static func icon(for kind: BlockKind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .astro: "square.on.square"
        case .customElement: "puzzlepiece"
        // `.element`/`.fragment` (#1222) are structural target kinds the sidecar transport
        // reports on existing nodes — no palette entry (`WYSIWYGCanvasController.stubBlockPalette`)
        // is ever built with either kind, but the switch must stay exhaustive.
        case .element: "chevron.left.slash.chevron.right"
        case .fragment: "square.dashed"
        }
    }
}
