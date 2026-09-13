import Testing
@testable import AnglesiteCore

/// `FoundationModelTier`'s alias bookkeeping (#1965): `.privateCloudCompute` is served on-device
/// until the PCC entitlement lands, and the revised LLM policy (2026-07-08 §8) says that must be
/// labeled, never silent.
@Suite("FoundationModelTier") struct FoundationModelTierTests {
    @Test("every tier is served on-device today")
    func everyTierServesOnDevice() {
        for tier in FoundationModelTier.allCases {
            #expect(tier.servingTier == .onDevice)
        }
    }

    @Test("only the PCC tier is degraded, and only it carries the badge")
    func onlyPCCIsDegraded() {
        #expect(!FoundationModelTier.onDevice.isDegraded)
        #expect(FoundationModelTier.onDevice.degradationNotice == nil)
        #expect(FoundationModelTier.privateCloudCompute.isDegraded)
        #expect(FoundationModelTier.privateCloudCompute.degradationNotice == FoundationModelTier.onDeviceDegradationNotice)
    }

    @Test("the badge is owner-phrased: names the on-device model and sets expectations")
    func badgeCopy() {
        let notice = FoundationModelTier.onDeviceDegradationNotice
        #expect(notice.contains("on-device model"))
        #expect(notice.contains("shorter"))
    }
}
