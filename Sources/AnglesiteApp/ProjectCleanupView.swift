import SwiftUI
import AnglesiteCore

/// Main-pane Cleanup surface (Website ▸ Cleanup…). Same rows and actions the sidebar Cleanup
/// section had before #714 moved it out of the visitor-facing navigator — opening the pane
/// auto-scans instead of waiting on a first-run "Scan" button, since there's no longer other
/// navigator content to sit alongside.
struct ProjectCleanupView: View {
    @Bindable var cleanup: ProjectCleanupModel
    var onOpen: (DeadAssetScanner.CleanupCandidate) -> Void
    var onDelete: (DeadAssetScanner.CleanupCandidate) async -> Void
    /// Returns the main pane to the canvas (#714 v2 slice 2's Done chrome) — Cleanup is a
    /// menu-invoked takeover (Website ▸ Cleanup…), not a peer toolbar pane.
    var onDone: () -> Void = {}
    @State private var candidateToDelete: DeadAssetScanner.CleanupCandidate?
    /// The title shown in the confirmation dialog. Held separately from `candidateToDelete` so the
    /// title stays stable through the dismiss animation — reading `candidateToDelete`'s property
    /// directly would collapse to "" the instant the dialog clears the optional.
    @State private var candidateToDeleteTitle: String = ""

    var body: some View {
        VStack(spacing: 0) {
            MainPaneTakeoverHeader(title: "Cleanup", systemImage: "trash", onDone: onDone)
            Divider()
            List {
                cleanupContent
            }
            .navigationSubtitle("Cleanup")
            .confirmationDialog(
                candidateToDeleteTitle,
                isPresented: Binding(
                    get: { candidateToDelete != nil },
                    set: { if !$0 { candidateToDelete = nil } }),
                titleVisibility: .visible,
                presenting: candidateToDelete
            ) { candidate in
                Button("Delete", role: .destructive) {
                    Task { await onDelete(candidate) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { candidate in
                Text(candidate.kind == .page
                    ? "This page has no incoming links and will be permanently removed."
                    : "This file appears unused and will be permanently removed.")
            }
            .alert(
                "Delete failed",
                isPresented: Binding(
                    get: { cleanup.deleteError != nil },
                    set: { if !$0 { cleanup.deleteError = nil } }),
                presenting: cleanup.deleteError
            ) { _ in
                Button("OK", role: .cancel) { cleanup.deleteError = nil }
            } message: { msg in
                Text(msg)
            }
            .task {
                if !cleanup.hasScanned && !cleanup.isBusy { await cleanup.scan() }
            }
        }
    }

    @ViewBuilder
    private var cleanupContent: some View {
        if !cleanup.hasScanned {
            Button {
                Task { await cleanup.scan() }
            } label: {
                Label(
                    cleanup.isScanning ? "Scanning…" : "Scan for Cleanup Opportunities",
                    systemImage: "sparkle.magnifyingglass")
            }
            .disabled(cleanup.isBusy)
        } else if cleanup.candidates.isEmpty {
            Text("No unused files found")
                .foregroundStyle(.secondary)
        } else {
            ForEach(cleanup.candidates) { candidate in
                Label(candidate.path, systemImage: cleanupIcon(for: candidate.kind))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contextMenu {
                        Button("Open") { onOpen(candidate) }
                        Button("Ignore") { cleanup.ignore(candidate) }
                        Button("Delete", role: .destructive) {
                            candidateToDeleteTitle = deleteConfirmationTitle(for: candidate)
                            candidateToDelete = candidate
                        }
                    }
            }
            Button {
                Task { await cleanup.scan() }
            } label: {
                Label(cleanup.isScanning ? "Scanning…" : "Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(cleanup.isBusy)
        }
    }

    private func cleanupIcon(for kind: DeadAssetScanner.CleanupCandidate.Kind) -> String {
        switch kind {
        case .component: return "square.stack.3d.up"
        case .layout: return "rectangle.stack"
        case .image: return "photo"
        case .page: return "doc.richtext"
        }
    }

    private func deleteConfirmationTitle(for candidate: DeadAssetScanner.CleanupCandidate) -> String {
        candidate.kind == .page
            ? "Delete “\(candidate.path)”?"
            : "Delete unused \(candidate.kind.rawValue) “\(candidate.path)”?"
    }
}
