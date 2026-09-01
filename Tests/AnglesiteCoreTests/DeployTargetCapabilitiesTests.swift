import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for `DeployTargetCapabilities` (#1683) — one flag per capability *family*, not per
/// feature: the worker catalog, Inbox Capture, and every future Workers-backed feature are all
/// "needs Cloudflare Workers," so they all read the same answer here.
struct DeployTargetCapabilitiesTests {
    @Test("only Cloudflare supports Workers-backed features")
    func supportsWorkers() {
        #expect(DeployTargetCapabilities.supportsWorkers(for: .cloudflare) == true)
        #expect(DeployTargetCapabilities.supportsWorkers(for: .githubPages) == false)
    }

    @Test("every known kind has an answer")
    func exhaustive() {
        // Guards against a future kind being added to `DeployTargetKind` and quietly inheriting
        // a `default:` answer — `supportsWorkers` must switch exhaustively.
        for kind in DeployTargetKind.allCases {
            #expect(DeployTargetCapabilities.supportsWorkers(for: kind) == (kind == .cloudflare))
        }
    }
}
