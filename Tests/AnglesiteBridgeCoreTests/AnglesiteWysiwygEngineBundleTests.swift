import Testing
import Foundation
@testable import AnglesiteBridgeCore

@Suite("AnglesiteWysiwygEngineBundle")
struct AnglesiteWysiwygEngineBundleTests {
    @Test("returns nil when the bundle resource is absent")
    func missingBundleReturnsNil() {
        // The test bundle (no "engine.js" resource under wysiwyg-engine/) stands in for a build
        // where the prebuild script was skipped — mirrors AnglesiteOverlayBundle's own case.
        #expect(AnglesiteWysiwygEngineBundle.source(in: Bundle.module) == nil)
    }
}
