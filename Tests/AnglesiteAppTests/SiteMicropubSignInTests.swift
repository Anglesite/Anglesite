import Testing
import AnglesiteIOS
@testable import AnglesiteAppCore

@Suite("SiteMicropubSignIn")
struct SiteMicropubSignInTests {
    @Test("conforms to SiteWebAuthenticating")
    func conformsToProtocol() {
        // ASWebAuthenticationSession can't be driven headlessly in a unit test; this only
        // confirms the type exists and conforms to the protocol `MicropubOnboardingModel`
        // expects. Real behavior (presenting the sheet, mapping cancellation) is exercised by
        // manual QA (documented in the PR).
        let signIn = SiteMicropubSignIn()
        #expect(signIn is any SiteWebAuthenticating)
    }
}
