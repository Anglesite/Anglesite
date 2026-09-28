import Testing
@testable import AnglesiteCore

struct ServedHeadersAuditTests {
    private static let declared: [String: String] = [
        "Content-Security-Policy": "default-src 'self'",
        "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
        "X-Frame-Options": "DENY",
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "strict-origin-when-cross-origin",
        "Permissions-Policy": "camera=(), microphone=()",
        // Not in the compared set — must never produce a finding either way.
        "Cross-Origin-Opener-Policy": "same-origin-allow-popups",
    ]

    @Test("every declared header served exactly produces no findings")
    func everyHeaderServedProducesNoFindings() {
        let findings = ServedHeadersAudit.evaluate(expected: Self.declared, served: Self.declared)
        #expect(findings.isEmpty)
    }

    @Test("a served header the file never declared is never flagged")
    func undeclaredServedHeaderIsNeverFlagged() {
        var served = Self.declared
        served["X-Powered-By"] = "PHP/8"
        let findings = ServedHeadersAudit.evaluate(expected: Self.declared, served: served)
        #expect(findings.isEmpty)
    }

    @Test("a missing Content-Security-Policy is one .edge .informational finding telling the owner to redeploy")
    func missingCSPIsOneInformationalFinding() {
        var served = Self.declared
        served.removeValue(forKey: "Content-Security-Policy")
        let findings = ServedHeadersAudit.evaluate(expected: Self.declared, served: served)
        #expect(findings.count == 1)
        #expect(findings[0].category == .edge)
        #expect(findings[0].remediation == .informational)
        #expect(findings[0].detail.localizedCaseInsensitiveContains("redeploy"))
    }

    @Test("a missing Strict-Transport-Security is flagged the same way as a missing CSP")
    func missingHSTSIsFlagged() {
        var served = Self.declared
        served.removeValue(forKey: "Strict-Transport-Security")
        let findings = ServedHeadersAudit.evaluate(expected: Self.declared, served: served)
        #expect(findings.count == 1)
        #expect(findings[0].title.contains("Strict-Transport-Security"))
    }

    @Test("CSP served with a different value is not flagged — presence-only")
    func cspDifferentValueIsPresenceOnly() {
        var served = Self.declared
        served["Content-Security-Policy"] = "default-src 'none'"
        let findings = ServedHeadersAudit.evaluate(expected: Self.declared, served: served)
        #expect(findings.isEmpty)
    }

    @Test("HSTS served with a different value is not flagged — presence-only")
    func hstsDifferentValueIsPresenceOnly() {
        var served = Self.declared
        served["Strict-Transport-Security"] = "max-age=0"
        let findings = ServedHeadersAudit.evaluate(expected: Self.declared, served: served)
        #expect(findings.isEmpty)
    }

    @Test("X-Frame-Options served as a different value names both values in the finding")
    func xFrameOptionsDifferentValueNamesBothValues() {
        var served = Self.declared
        served["X-Frame-Options"] = "SAMEORIGIN"
        let findings = ServedHeadersAudit.evaluate(expected: Self.declared, served: served)
        #expect(findings.count == 1)
        #expect(findings[0].category == .edge)
        #expect(findings[0].remediation == .informational)
        #expect(findings[0].detail.contains("DENY"))
        #expect(findings[0].detail.contains("SAMEORIGIN"))
    }

    @Test("exact-value headers match case-insensitively by name and after trimming whitespace")
    func exactValueMatchIsCaseInsensitiveOnNameAndTrimmed() {
        var served = Self.declared
        served.removeValue(forKey: "X-Frame-Options")
        served["x-frame-options"] = "  DENY  "
        let findings = ServedHeadersAudit.evaluate(expected: Self.declared, served: served)
        #expect(findings.isEmpty)
    }

    @Test("value comparison is case-sensitive after trimming")
    func exactValueComparisonIsCaseSensitive() {
        var served = Self.declared
        served["X-Frame-Options"] = "deny"
        let findings = ServedHeadersAudit.evaluate(expected: Self.declared, served: served)
        #expect(findings.count == 1)
    }

    @Test("a header the declared file never mentions is never evaluated, even if served differently")
    func headerNotDeclaredIsNeverEvaluated() {
        let expected = ["X-Frame-Options": "DENY"]
        let served = ["X-Frame-Options": "DENY", "Permissions-Policy": "camera=()"]
        let findings = ServedHeadersAudit.evaluate(expected: expected, served: served)
        #expect(findings.isEmpty)
    }

    @Test("multiple drifted headers are all reported, in fixed order")
    func multipleDriftedHeadersAllReported() {
        var served = Self.declared
        served.removeValue(forKey: "Content-Security-Policy")
        served["X-Frame-Options"] = "SAMEORIGIN"
        let findings = ServedHeadersAudit.evaluate(expected: Self.declared, served: served)
        #expect(findings.count == 2)
        #expect(findings[0].title.contains("Content-Security-Policy"))
        #expect(findings[1].title.contains("X-Frame-Options"))
    }
}
