/// Diffs a site's declared root-path headers (parsed from `dist/_headers` via
/// ``HeadersFileParser``) against what a live probe actually received, turning drift into
/// `DomainConfigAudit.Finding`s (#2007). Pure — no I/O; ``ServedHeadersProbing`` owns the network
/// hop, and the caller decides when to skip the check entirely (no `dist/_headers`, GitHub Pages
/// deploy target, an unanswerable probe).
public enum ServedHeadersAudit {
    /// Compared by presence only: both are long, and a proxy legitimately reorders or extends a
    /// CSP, so a byte-diff would fire constantly and teach owners to ignore the check (#2007
    /// resolved default 4).
    private static let presenceOnly: Set<String> = [
        "content-security-policy", "strict-transport-security",
    ]
    /// Compared for presence and exact value.
    private static let exactValue: Set<String> = [
        "x-frame-options", "x-content-type-options", "referrer-policy", "permissions-policy",
    ]
    /// Fixed report order. Headers `_headers` declares outside this set
    /// (`Cross-Origin-Opener-Policy`, `Cross-Origin-Resource-Policy`, `Cache-Control`, `Link`)
    /// aren't graded — they're either non-security metadata or not part of the security-header set
    /// the parent issue (#1994) calls out, and grading them was never asked for.
    private static let order = [
        "content-security-policy", "strict-transport-security",
        "x-frame-options", "x-content-type-options", "referrer-policy", "permissions-policy",
    ]
    private static let displayNames: [String: String] = [
        "content-security-policy": "Content-Security-Policy",
        "strict-transport-security": "Strict-Transport-Security",
        "x-frame-options": "X-Frame-Options",
        "x-content-type-options": "X-Content-Type-Options",
        "referrer-policy": "Referrer-Policy",
        "permissions-policy": "Permissions-Policy",
    ]

    /// - Parameters:
    ///   - expected: The declared `_headers` root (`/*`) block, as ``HeadersFileParser`` returns
    ///     it. Header names not in the compared set are ignored; never flags a served header the
    ///     file doesn't declare.
    ///   - served: The response headers a live probe actually received.
    /// - Returns: `.edge` `.informational` findings, in fixed report order; empty when everything
    ///   declared is being served as declared.
    public static func evaluate(expected: [String: String], served: [String: String]) -> [DomainConfigAudit.Finding] {
        let expectedLower = lowercasedKeys(expected)
        let servedLower = lowercasedKeys(served)
        var findings: [DomainConfigAudit.Finding] = []

        for name in order {
            guard let declaredValue = expectedLower[name] else { continue }
            let displayName = displayNames[name] ?? name

            guard let servedValue = servedLower[name] else {
                findings.append(.init(
                    category: .edge,
                    title: "\(displayName) isn't being served",
                    detail: "Your site declares \(displayName), but the live site didn't send it back. "
                        + "Your security headers aren't being served — try redeploying.",
                    remediation: .informational))
                continue
            }

            guard exactValue.contains(name) else { continue }
            let trimmedDeclared = declaredValue.trimmingCharacters(in: .whitespaces)
            let trimmedServed = servedValue.trimmingCharacters(in: .whitespaces)
            guard trimmedDeclared != trimmedServed else { continue }
            findings.append(.init(
                category: .edge,
                title: "\(displayName) doesn't match what's served",
                detail: "Your site declares \(displayName) as \"\(trimmedDeclared)\", but the live site "
                    + "is serving \"\(trimmedServed)\". Your security headers aren't being served as "
                    + "configured — try redeploying.",
                remediation: .informational))
        }
        return findings
    }

    private static func lowercasedKeys(_ headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in headers { result[key.lowercased()] = value }
        return result
    }
}
