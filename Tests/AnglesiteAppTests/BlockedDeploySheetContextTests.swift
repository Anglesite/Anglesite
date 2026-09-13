import Testing
@testable import AnglesiteAppCore

/// #1959's `BlockedDeploySheetView` fronts Deploy, "Publish to GitHub", AND Backup refusals with
/// one no-override sheet. Its header used to be hardcoded to Deploy/Publish's "Can't publish
/// yet" / "…before this site can ship" copy even when presented for a blocked Backup — telling
/// an owner who only asked to back up their site that it "can't ship" (PR #1981 review). This
/// locks in that `.backup` gets its own consequence-phrased copy, distinct from `.shipping`'s.
@Suite("BlockedDeploySheetView.Context copy (#1959, PR #1981 review)")
struct BlockedDeploySheetContextTests {
    @Test("backup context does not reuse the shipping/publish copy")
    func backupContextHasItsOwnCopy() {
        let shipping = BlockedDeploySheetView.Context.shipping
        let backup = BlockedDeploySheetView.Context.backup

        #expect(shipping.title != backup.title)
        #expect(shipping.subtitle != backup.subtitle)
    }

    @Test("backup context does not talk about publishing or shipping")
    func backupContextDoesNotMentionShipping() {
        let backup = BlockedDeploySheetView.Context.backup

        #expect(!backup.title.localizedCaseInsensitiveContains("publish"))
        #expect(!backup.title.localizedCaseInsensitiveContains("ship"))
        #expect(!backup.subtitle.localizedCaseInsensitiveContains("publish"))
        #expect(!backup.subtitle.localizedCaseInsensitiveContains("ship"))
    }
}
