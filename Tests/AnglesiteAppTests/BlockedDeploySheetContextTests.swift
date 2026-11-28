import Testing
@testable import AnglesiteAppCore

/// #1959's `BlockedDeploySheetView` fronts Deploy, "Publish to GitHub", AND Backup refusals with
/// one no-override sheet. Its header used to be hardcoded to Deploy/Publish's "Can't publish
/// yet" / "…before this site can ship" copy even when presented for a blocked Backup — telling
/// an owner who only asked to back up their site that it "can't ship" (PR #1981 review). This
/// locks in that `.backup` gets its own consequence-phrased copy, distinct from `.shipping`'s.
@Suite("BlockedDeploySheetView.Context copy (#1959, PR #1981 review, #2211)")
struct BlockedDeploySheetContextTests {
    @Test("backup context does not reuse the shipping/publish copy")
    func backupContextHasItsOwnCopy() {
        let shipping = BlockedDeploySheetView.Context.shipping
        let backup = BlockedDeploySheetView.Context.backup

        #expect(shipping.title != backup.title)
        #expect(shipping.reassurance != backup.reassurance)
        #expect(shipping.nextStep != backup.nextStep)
    }

    @Test("backup context does not talk about publishing or shipping")
    func backupContextDoesNotMentionShipping() {
        let backup = BlockedDeploySheetView.Context.backup

        #expect(!backup.title.localizedCaseInsensitiveContains("publish"))
        #expect(!backup.title.localizedCaseInsensitiveContains("ship"))
        for line in [backup.reassurance, backup.nextStep] {
            #expect(!line.localizedCaseInsensitiveContains("publish"))
            #expect(!line.localizedCaseInsensitiveContains("ship"))
        }
    }

    /// #2211: with no override, the header must always say that nothing left the Mac and the
    /// owner's edits are safe — the reassurance is required content, not decoration.
    @Test("every context says nothing went out and edits are saved",
          arguments: [BlockedDeploySheetView.Context.shipping, .backup])
    func reassuranceSaysWhatIsSafe(context: BlockedDeploySheetView.Context) {
        #expect(context.reassurance.localizedCaseInsensitiveContains("nothing was"))
        #expect(context.reassurance.localizedCaseInsensitiveContains("your edits are saved"))
    }
}
