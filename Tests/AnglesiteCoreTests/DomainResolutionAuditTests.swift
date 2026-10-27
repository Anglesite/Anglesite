import Testing
@testable import AnglesiteCore

struct DomainResolutionAuditTests {
    private let domain = "example.com"

    @Test("apex and www both resolving produces no findings")
    func bothResolvedProducesNoFindings() {
        let findings = DomainResolutionAudit.evaluate(domain: domain, apex: .resolved, www: .resolved)
        #expect(findings.isEmpty)
    }

    @Test("apex not resolving, www resolving still shows the apex finding")
    func apexNotResolvedWWWResolved() {
        let findings = DomainResolutionAudit.evaluate(domain: domain, apex: .notResolved, www: .resolved)
        #expect(findings.count == 1)
        #expect(findings[0].category == .dns)
        #expect(findings[0].remediation == .informational)
        #expect(findings[0].detail.contains(domain))
        #expect(findings[0].detail.contains("visitors"))
    }

    @Test("apex resolving, www not resolving is an owner question about visitors")
    func apexResolvedWWWNotResolved() {
        let findings = DomainResolutionAudit.evaluate(domain: domain, apex: .resolved, www: .notResolved)
        #expect(findings.count == 1)
        #expect(findings[0].category == .dns)
        guard case .ownerQuestion(let question) = findings[0].remediation else {
            Issue.record("expected .ownerQuestion")
            return
        }
        #expect(question.contains("www.\(domain)"))
        #expect(question.contains(domain))
        #expect(!question.lowercased().contains("cname"))
        #expect(!question.lowercased().contains(" a record"))
    }

    @Test("neither apex nor www resolving shows exactly the apex finding, not two")
    func neitherResolvedShowsOnlyApexFinding() {
        let findings = DomainResolutionAudit.evaluate(domain: domain, apex: .notResolved, www: .notResolved)
        #expect(findings.count == 1)
        #expect(findings[0].remediation == .informational)
    }

    @Test("an indeterminate apex result produces zero findings regardless of www")
    func indeterminateApexProducesNoFindings() {
        #expect(DomainResolutionAudit.evaluate(domain: domain, apex: .indeterminate, www: .resolved).isEmpty)
        #expect(DomainResolutionAudit.evaluate(domain: domain, apex: .indeterminate, www: .notResolved).isEmpty)
        #expect(DomainResolutionAudit.evaluate(domain: domain, apex: .indeterminate, www: .indeterminate).isEmpty)
    }

    @Test("an indeterminate www result with a resolving apex produces zero findings")
    func indeterminateWWWWithResolvedApexProducesNoFindings() {
        let findings = DomainResolutionAudit.evaluate(domain: domain, apex: .resolved, www: .indeterminate)
        #expect(findings.isEmpty)
    }

    @Test("evaluate is pure: identical inputs produce identical findings with a stable id")
    func evaluateIsPureAndStable() {
        let first = DomainResolutionAudit.evaluate(domain: domain, apex: .resolved, www: .notResolved)
        let second = DomainResolutionAudit.evaluate(domain: domain, apex: .resolved, www: .notResolved)
        #expect(first == second)
        #expect(first.map(\.id) == second.map(\.id))
    }
}
