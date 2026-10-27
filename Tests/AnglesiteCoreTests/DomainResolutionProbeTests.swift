import Testing
import Foundation
@testable import AnglesiteCore

struct DomainResolutionProbeTests {
    @Test("a lookup that returns true is .resolved")
    func lookupTrueIsResolved() async {
        let probe = SystemDomainResolutionProbe(lookup: { _ in true })
        let result = await probe.resolve(host: "example.com")
        #expect(result == .resolved)
    }

    @Test("a lookup that returns false is .notResolved")
    func lookupFalseIsNotResolved() async {
        let probe = SystemDomainResolutionProbe(lookup: { _ in false })
        let result = await probe.resolve(host: "no-such-domain.invalid")
        #expect(result == .notResolved)
    }

    @Test("a lookup that throws (timeout/transient failure) is .indeterminate")
    func lookupThrowsIsIndeterminate() async {
        let probe = SystemDomainResolutionProbe(lookup: { _ in throw URLError(.timedOut) })
        let result = await probe.resolve(host: "example.com")
        #expect(result == .indeterminate)
    }

    @Test("resolve passes the requested host through to the lookup")
    func resolvePassesHostThrough() async {
        let requested = LockedBox<String?>(nil)
        let probe = SystemDomainResolutionProbe(lookup: { host in
            requested.value = host
            return true
        })
        _ = await probe.resolve(host: "www.example.com")
        #expect(requested.value == "www.example.com")
    }
}

/// Minimal thread-safe box for capturing a value from inside a `@Sendable` closure in a test.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
