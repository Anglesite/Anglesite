import Testing
@testable import AnglesiteContainer

/// Pure-logic coverage for `BundledImageError`'s remediation text (#1429). No VM boot or
/// entitlement needed — unlike the rest of this target's suites — but it lives here anyway
/// because `BundledImage`/`BundledImageError` are only visible from AnglesiteContainer, whose
/// product this target already links.
struct BundledImageErrorTests {
    @Test("each NotProvisioned case names the vendor script that fixes it")
    func describesRemediation() {
        #expect("\(BundledImageError.imageLayoutNotProvisioned)".contains("scripts/vendor-container-image.sh"))
        #expect("\(BundledImageError.kernelNotProvisioned)".contains("scripts/vendor-container-kernel.sh"))
        #expect("\(BundledImageError.initfsNotProvisioned)".contains("scripts/vendor-container-kernel.sh"))
    }

    @Test("missingDescriptions surfaces the remediation for every unprovisioned artifact")
    func missingDescriptionsIncludeRemediation() {
        let report = BundledImageProvisioningReport(
            image: .missing(reason: "\(BundledImageError.imageLayoutNotProvisioned)"),
            kernel: .missing(reason: "\(BundledImageError.kernelNotProvisioned)"),
            initfs: .missing(reason: "\(BundledImageError.initfsNotProvisioned)")
        )
        #expect(report.missingDescriptions.count == 3)
        #expect(report.missingDescriptions.allSatisfy { $0.contains("scripts/vendor-container") })
    }
}
