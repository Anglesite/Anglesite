import Testing
@testable import AnglesiteCore

@Suite struct GeneratedDesignDocumentTests {
    @Test func isOwnedTrueOnlyWhenMarkerIsTheFirstLine() {
        #expect(GeneratedDesignDocument.isOwned(GeneratedDesignDocument.marker + "\n\n# Design\n"))
        #expect(!GeneratedDesignDocument.isOwned("# Design\n\n" + GeneratedDesignDocument.marker))
        #expect(!GeneratedDesignDocument.isOwned("# Hand-authored"))
        #expect(!GeneratedDesignDocument.isOwned(""))
        #expect(!GeneratedDesignDocument.isOwned(nil))
    }
}
