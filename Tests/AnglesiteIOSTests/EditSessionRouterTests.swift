import Foundation
import Testing
@testable import AnglesiteIOS

@MainActor
@Suite("EditSessionRouter")
struct EditSessionRouterTests {
    @Test("a request is held until consumed, then cleared")
    func requestAndConsume() {
        let router = EditSessionRouter()
        let id = UUID()
        #expect(router.requestedSiteID == nil)
        router.requestEditSession(siteID: id)
        #expect(router.requestedSiteID == id)
        #expect(router.consume() == id)
        #expect(router.requestedSiteID == nil)
        #expect(router.consume() == nil)
    }

    @Test("the last request wins")
    func lastRequestWins() {
        let router = EditSessionRouter()
        let first = UUID()
        let second = UUID()
        router.requestEditSession(siteID: first)
        router.requestEditSession(siteID: second)
        #expect(router.consume() == second)
    }
}
