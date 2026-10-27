/// Pure evaluator: turns a pair of ``DomainResolutionResult``s (apex + `www`) into
/// ``DomainConfigAudit/Finding``s. Companion to `DomainConfigAudit`'s declared-vs-live diff —
/// this half checks a live *name-resolution* fact rather than declared Cloudflare state, but
/// reports through the same `Finding` type (`category: .dns`) so the app surfaces both kinds of
/// drift in one list (#2006).
///
/// Read-only, no I/O — the probing itself lives in `DomainResolutionProbing`; this type only
/// interprets already-probed results, so it stays trivially testable and, per `DomainConfigAudit`'s
/// existing purity contract, produces the same findings (with the same `Finding.id`) for the same
/// inputs across repeated calls.
public enum DomainResolutionAudit {
    /// Grades a domain's live name resolution.
    ///
    /// - Parameters:
    ///   - domain: The site's declared apex hostname (used in finding text; also the `www` prefix
    ///     base).
    ///   - apex: Whether `domain` itself resolved.
    ///   - www: Whether `www.<domain>` resolved.
    /// - Returns: Zero or one finding. An `apex` of `.indeterminate` always yields zero findings
    ///   (rule: "we could not tell" is never reported as drift) — and since the `www` finding only
    ///   makes sense relative to a *known-resolving* apex, `www` is only evaluated when `apex ==
    ///   .resolved`; `www == .indeterminate` there likewise yields zero findings.
    public static func evaluate(
        domain: String, apex: DomainResolutionResult, www: DomainResolutionResult
    ) -> [DomainConfigAudit.Finding] {
        switch apex {
        case .indeterminate:
            return []
        case .notResolved:
            return [.init(
                category: .dns,
                title: "Domain doesn't resolve",
                detail: "\(domain) doesn't resolve to an address yet, so visitors trying to reach it get nothing. This is usually DNS propagation still catching up, or a registrar setting outside Anglesite.",
                remediation: .informational)]
        case .resolved:
            guard www == .notResolved else { return [] }
            return [.init(
                category: .dns,
                title: "www doesn't resolve",
                detail: "\(domain) works, but www.\(domain) doesn't resolve — a visitor who types the www form reaches nothing.",
                remediation: .ownerQuestion(
                    "Visitors who type \"www.\(domain)\" instead of \"\(domain)\" currently reach nothing, even though \(domain) itself works. Do you want the www address to work too?"))]
        }
    }
}
