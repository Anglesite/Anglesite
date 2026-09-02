import Foundation

/// Thrown by `waitUntil(_:timeout:isolation:_:)` when its condition never held before the
/// deadline; the test framework reports the thrown error as the failure.
public struct WaitUntilTimeout: Error, CustomStringConvertible {
    /// The caller's description of what was being waited for.
    public let what: String
    /// How long the poll ran before giving up.
    public let timeout: Duration

    public var description: String {
        "timed out after \(timeout) waiting for \(what)"
    }
}

/// Polls `condition` until it holds, throwing `WaitUntilTimeout` if `timeout` elapses first.
///
/// This is the event-driven replacement for a fixed `Task.sleep` before an assertion: a passing
/// test returns as soon as the condition holds, while the deadline only bounds how long a
/// genuine failure hangs — which is why the default is deliberately generous. A tight deadline
/// just makes a suite flaky under parallel CI or concurrent-agent load (#762, #1721).
///
/// The poll runs on the caller's own isolation (`#isolation`), so a `@MainActor` suite can pass
/// a closure that reads main-actor state (`router.messages.count == 1`) without it having to be
/// `@Sendable`.
///
/// - Parameters:
///   - what: What the condition represents, for the timeout message.
///   - timeout: Deadline after which the poll gives up.
///   - isolation: The caller's actor; defaulted, never passed explicitly.
///   - condition: Re-evaluated every 10 ms until it returns `true`.
/// - Throws: `WaitUntilTimeout` if `condition` never held before `timeout`.
public func waitUntil(
    _ what: String = "condition",
    timeout: Duration = .seconds(30),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else {
            throw WaitUntilTimeout(what: what, timeout: timeout)
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
