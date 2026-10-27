import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What a name-resolution probe learned about a hostname. Three-valued rather than a `Bool` for
/// the same reason as ``SitemapPreflightResult``: a lookup that failed for reasons other than "no
/// such name" (timeout, transient resolver error, cancellation) must never be conflated with a
/// definitive "doesn't resolve" — this probe is advisory, so only a definitive answer may be
/// reported to the owner as drift (#2006).
public enum DomainResolutionResult: Sendable, Equatable {
    /// The resolver returned at least one address for the hostname.
    case resolved
    /// The resolver definitively said no such name exists (`EAI_NONAME`).
    case notResolved
    /// Anything that isn't a definitive answer: timeout, a transient resolver failure, or
    /// cancellation. Treat as "don't know" — see ``DomainResolutionAudit``'s rule that this
    /// produces no finding at all.
    case indeterminate
}

/// Probes whether a hostname resolves, so `DomainConfigAuditModel` can surface DNS propagation
/// problems (apex/`www` not resolving) before the owner discovers them as a dead link. Seam-shaped
/// like ``SitemapPreflighting``: tests stub it, never hitting a real resolver.
public protocol DomainResolutionProbing: Sendable {
    /// Looks up `host`. Never throws — every failure mode is folded into
    /// ``DomainResolutionResult``.
    func resolve(host: String) async -> DomainResolutionResult
}

/// The raw lookup: `true` if `host` resolves to at least one address, `false` if the resolver
/// definitively says no such host exists, and throws for anything else (timeout, transient
/// failure) — mirroring `CloudflareTransport`'s seam shape.
public typealias DomainLookupTransport = @Sendable (String) async throws -> Bool

/// Failure modes for ``DomainLookupTransport``'s production default.
enum DomainLookupError: Error, Sendable {
    case timedOut
    case resolverError(Int32)
}

/// Live implementation: a system `getaddrinfo(3)` lookup with a short timeout. `getaddrinfo` is a
/// blocking syscall with no cancellable/async variant on either Darwin or Glibc, so the timeout is
/// enforced by racing it against a sleep — the loser's underlying syscall isn't interrupted, it's
/// just abandoned, exactly as a slow resolver would time out from the caller's perspective.
public struct SystemDomainResolutionProbe: DomainResolutionProbing {
    /// Short deliberately: this runs inline in a flow the owner is waiting on, and a slow answer
    /// must not hold them hostage for an advisory result — same rationale and value as
    /// `HTTPSitemapPreflight.timeout`.
    private static let timeout: TimeInterval = 5
    private let lookup: DomainLookupTransport

    /// The lookup parameter exists for tests (deterministic results, no network/resolver);
    /// production uses ``defaultLookup``.
    public init(lookup: @escaping DomainLookupTransport = SystemDomainResolutionProbe.defaultLookup) {
        self.lookup = lookup
    }

    /// Production lookup: races a blocking `getaddrinfo` call against a 5s timeout.
    public static let defaultLookup: DomainLookupTransport = { host in
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try Self.systemResolve(host: host)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(SystemDomainResolutionProbe.timeout * 1_000_000_000))
                throw DomainLookupError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw DomainLookupError.timedOut
            }
            return first
        }
    }

    public func resolve(host: String) async -> DomainResolutionResult {
        do {
            let found = try await lookup(host)
            return found ? .resolved : .notResolved
        } catch {
            return .indeterminate
        }
    }

    private static func systemResolve(host: String) throws -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        // Glibc types SOCK_STREAM as __socket_type (an enum), not addrinfo.ai_socktype's Int32 —
        // Darwin's is already Int32. .rawValue only exists on the Glibc enum, hence the #if.
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #elseif canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var infoPointer: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &infoPointer)
        defer { if let infoPointer { freeaddrinfo(infoPointer) } }
        switch status {
        case 0:
            return true
        case EAI_NONAME:
            return false
        default:
            throw DomainLookupError.resolverError(status)
        }
    }
}
