import Foundation
import Observation
import AnglesiteCore

/// Drives the Review Copy sheet (#465): runs the chunked audit, tracks per-finding apply state,
/// and performs the deterministic excerpt-replacement apply. Depends only on `CopyEditAuditing`
/// so tests inject fakes; `auditor == nil` covers only the pre-6.4 toolchain, rendering the
/// disabled-with-explanation state per the LLM policy. Apple Intelligence being off *at runtime*
/// (a Swift 6.4 build, but the model unavailable) is a separate case: the auditor exists but
/// `report?.unavailableMessage` is set instead — the view shows the same explanation for both.
@Observable @MainActor
final class CopyEditReportModel: Identifiable {
    let id = UUID()
    let siteID: String
    let sourceDirectory: URL
    private let auditor: (any CopyEditAuditing)?
    private let conventionsStore: ProjectConventionsStore

    var report: CopyEditReport?
    var running = false
    var appliedFindingIDs: Set<String> = []
    var annotatedFindingIDs: Set<String> = []
    var errorMessage: String?

    var unavailable: Bool { auditor == nil }

    init(siteID: String, sourceDirectory: URL, conventionsStore: ProjectConventionsStore,
         auditor: (any CopyEditAuditing)? = CopyEditAuditorFactory.makeDefault()) {
        self.siteID = siteID
        self.sourceDirectory = sourceDirectory
        self.conventionsStore = conventionsStore
        self.auditor = auditor
    }

    func run() async {
        guard let auditor, !running else { return }
        running = true
        defer { running = false }
        let chunks = SiteContentChunker.chunks(sourceDirectory: sourceDirectory)
        let conventions = await conventionsStore.load()
        let preamble = BrandVoiceGuidance.preamble(
            conventions: conventions,
            businessType: SiteBusinessType.read(sourceDirectory: sourceDirectory))
        report = await auditor.audit(chunks: chunks, preamble: preamble,
                                     siteID: siteID, siteDirectory: sourceDirectory)
    }

    /// Whether Apply can work: the excerpt must appear verbatim in the file right now.
    func canApply(_ finding: CopyFinding) -> Bool {
        guard !appliedFindingIDs.contains(finding.id),
              let contents = try? String(contentsOf: fileURL(finding), encoding: .utf8) else { return false }
        return CopyRewriteApplier.apply(excerpt: finding.excerpt, rewrite: finding.suggestedRewrite,
                                        contents: contents) != nil
    }

    func apply(_ finding: CopyFinding) {
        do {
            let url = fileURL(finding)
            let contents = try String(contentsOf: url, encoding: .utf8)
            guard let updated = CopyRewriteApplier.apply(
                excerpt: finding.excerpt, rewrite: finding.suggestedRewrite, contents: contents) else {
                errorMessage = String(localized: "The page text changed since the review — this excerpt no longer matches.")
                return
            }
            try updated.write(to: url, atomically: true, encoding: .utf8)
            appliedFindingIDs.insert(finding.id)
        } catch {
            errorMessage = String(localized: "Couldn't apply the rewrite: \(error.localizedDescription)")
        }
    }

    func saveAsAnnotation(_ finding: CopyFinding) {
        do {
            try AnnotationStore.add(
                in: sourceDirectory,
                path: finding.route,
                selector: "",
                text: "Copy review [\(finding.category)]: \(finding.issue) Suggestion: \(finding.suggestedRewrite)",
                sourceFile: finding.filePath)
            annotatedFindingIDs.insert(finding.id)
        } catch {
            errorMessage = String(localized: "Couldn't save the annotation: \(error.localizedDescription)")
        }
    }

    private func fileURL(_ finding: CopyFinding) -> URL {
        sourceDirectory.appendingPathComponent(finding.filePath)
    }
}
