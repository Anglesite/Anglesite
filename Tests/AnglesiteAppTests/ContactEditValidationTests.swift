import Testing
import Foundation
@testable import AnglesiteAppCore

@Suite("ContactEditValidation")
struct ContactEditValidationTests {
    @Test("rejects an empty (or whitespace-only) name")
    func rejectsEmptyName() {
        let result = ContactEditValidation.validate(
            displayName: "   ", meText: "https://example.com")
        guard case .failure(let message) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(message == "Enter a name.")
    }

    @Test("rejects a non-http(s) URL")
    func rejectsNonHTTPURL() {
        let result = ContactEditValidation.validate(displayName: "Alice", meText: "ftp://example.com")
        guard case .failure = result else {
            Issue.record("expected failure")
            return
        }
    }

    @Test("rejects unparseable text")
    func rejectsUnparseableText() {
        let result = ContactEditValidation.validate(displayName: "Alice", meText: "not a url")
        guard case .failure = result else {
            Issue.record("expected failure")
            return
        }
    }

    @Test("trims whitespace and accepts a valid https URL")
    func acceptsValidInput() {
        let result = ContactEditValidation.validate(
            displayName: "  Alice  ", meText: "  https://alice.example  ")
        guard case .success(let url, let displayName) = result else {
            Issue.record("expected success")
            return
        }
        #expect(displayName == "Alice")
        #expect(url.absoluteString == "https://alice.example")
    }

    @Test("accepts a plain http URL")
    func acceptsHTTP() {
        let result = ContactEditValidation.validate(displayName: "Bob", meText: "http://bob.example")
        guard case .success = result else {
            Issue.record("expected success")
            return
        }
    }
}
