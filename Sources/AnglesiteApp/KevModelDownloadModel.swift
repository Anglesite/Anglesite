import Foundation
import Observation
import AnglesiteCore

/// App-wide state for the on-demand screening model (#2068): whether the Kev-0.5B assets are
/// installed on this Mac, a download in flight, or the last attempt's failure. One instance
/// (`shared`) because Settings ▸ General and every site window's one-time offer act on the same
/// per-Mac directory (`KevModelLocator.defaultDirectory`), not on a site.
///
/// Owner vocabulary only on the surface (decision D1): "Downloading…", "Ready", "Couldn't
/// download". Byte counts, digests and paths go to the Debug pane via `KevModelDownloader`'s
/// own logging and the lines this model adds.
@MainActor
@Observable
final class KevModelDownloadModel {
    static let shared = KevModelDownloadModel()

    enum Status: Equatable {
        /// Probed, and no model directory is present.
        case notInstalled
        case downloading(KevModelDownloadProgress)
        case installed
        /// The last download failed; the message is for the Debug pane, the surface says "try again".
        case failed(String)
    }

    private(set) var status: Status = .notInstalled
    /// Whether there is anything to offer at all: a download is pinned, or a model is already
    /// installed (so it can be removed).
    var isAvailable: Bool { KevModelAssetPin.isConfigured || status != .notInstalled }

    private var downloadTask: Task<Void, Never>?

    private init() {
        Task { await refresh() }
    }

    /// Re-probes the model directory. Off the main actor: five `fileExists` calls under
    /// Application Support.
    func refresh() async {
        if case .downloading = status { return }
        let installed = await Task.detached { KevModelLocator.installedAssets() != nil }.value
        switch (installed, status) {
        case (true, _): status = .installed
        case (false, .failed): break  // keep the failure visible until the next attempt
        case (false, _): status = .notInstalled
        }
    }

    /// Starts the download unless one is already running. Progress lands in ``status``; the
    /// screening factory picks the installed directory up on the next site open with no further
    /// wiring (`InteractionScreenerFactory.makeDefault`).
    func download() {
        guard downloadTask == nil, let downloader = KevModelDownloader.makeDefault() else { return }
        status = .downloading(KevModelDownloadProgress(bytesReceived: 0, bytesExpected: 0, filesCompleted: 0, fileCount: 0))
        downloadTask = Task { [weak self] in
            defer { self?.downloadTask = nil }
            do {
                try await downloader.install { progress in
                    await MainActor.run { self?.status = .downloading(progress) }
                }
                self?.status = .installed
            } catch {
                self?.status = .failed("\(error)")
                await LogCenter.shared.append(source: "KevModelDownload", stream: .stderr,
                                              text: "Screening model download failed: \(error)")
            }
        }
    }

    /// Deletes the installed model; the screen returns to inert on the next site open.
    func remove() async {
        guard let directory = KevModelLocator.defaultDirectory() else { return }
        do {
            try await Task.detached { try KevModelDownloader.remove(at: directory) }.value
            status = .notInstalled
            await LogCenter.shared.append(source: "KevModelDownload", stream: .stdout,
                                          text: "Screening model removed from \(directory.path)")
        } catch {
            status = .failed("\(error)")
            await LogCenter.shared.append(source: "KevModelDownload", stream: .stderr,
                                          text: "Screening model removal failed: \(error)")
        }
    }
}
