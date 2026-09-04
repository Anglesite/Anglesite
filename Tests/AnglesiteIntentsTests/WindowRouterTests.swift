import Testing
@testable import AnglesiteIntents

/// `.serialized` because every test mutates the `WindowRouter.shared` singleton (`requested` +
/// `pendingNavigation`); without it Swift Testing may run them concurrently and one test's writes
/// can clobber another's assertions. Matches the `ContentPipelineE2E` suite's serialization.
@MainActor
@Suite(.serialized)
struct WindowRouterTests {
    /// Reset the shared singleton's state for the site ids a test touches.
    private func freshRouter() -> WindowRouter {
        let router = WindowRouter.shared
        router.requested = nil
        for id in ["siteA", "siteB", "siteC"] {
            _ = router.consumeNavigation(for: id)
            _ = router.consumeDesignInterviewRequest(for: id)
        }
        return router
    }

    @Test("requestOpen with a route sets the open trigger and stores the route once")
    func requestOpenWithRoute() {
        let router = freshRouter()
        router.requestOpen(siteID: "siteA", route: "/about")
        #expect(router.requested == "siteA")
        #expect(router.consumeNavigation(for: "siteA") == "/about")   // navigate to the route
        #expect(router.consumeNavigation(for: "siteA") == nil)        // consumed once → absent
    }

    @Test("requestOpen without a route records a reset-to-root request")
    func requestOpenNoRouteResetsToRoot() {
        let router = freshRouter()
        router.requestOpen(siteID: "siteB")
        #expect(router.requested == "siteB")
        // Present-but-nil ("reset the preview to the site root"), distinct from "nothing pending".
        guard case .some(let route) = router.consumeNavigation(for: "siteB") else {
            Issue.record("expected a pending reset entry for siteB")
            return
        }
        #expect(route == nil)
        #expect(router.consumeNavigation(for: "siteB") == nil)        // consumed once → absent
    }

    @Test("a navigation requested for one site is not consumed by another")
    func navigationIsPerSite() {
        let router = freshRouter()
        router.requestOpen(siteID: "siteA", route: "/contact")
        #expect(router.consumeNavigation(for: "siteB") == nil)
        #expect(router.consumeNavigation(for: "siteA") == "/contact")
    }

    @Test("re-requesting a site overwrites the still-pending navigation (last wins)")
    func reRequestOverwrites() {
        let router = freshRouter()
        router.requestOpen(siteID: "siteA", route: "/about")
        router.requestOpen(siteID: "siteA", route: "/contact")
        #expect(router.consumeNavigation(for: "siteA") == "/contact")
        #expect(router.consumeNavigation(for: "siteA") == nil)
    }

    @Test("requestDesignInterview sets the open trigger and records a pending request once")
    func requestDesignInterviewSetsPendingRequest() {
        let router = freshRouter()
        router.requestDesignInterview(siteID: "siteA")
        #expect(router.requested == "siteA")
        #expect(router.consumeDesignInterviewRequest(for: "siteA"))
        #expect(!router.consumeDesignInterviewRequest(for: "siteA"))   // consumed once → false
    }

    @Test("a design-interview request for one site is not consumed by another")
    func designInterviewRequestIsPerSite() {
        let router = freshRouter()
        router.requestDesignInterview(siteID: "siteA")
        #expect(!router.consumeDesignInterviewRequest(for: "siteB"))
        #expect(router.consumeDesignInterviewRequest(for: "siteA"))
    }
}
