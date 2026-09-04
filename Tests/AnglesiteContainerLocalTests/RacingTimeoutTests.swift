import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteContainer

/// Unit tests for `ContainerizationControl.racingTimeout`, the generic async race primitive behind
/// #498's VM-boot timeout. Unlike `ContainerizationControlTests`, these need no Virtualization
/// entitlement, bundled boot artifacts, or Apple-Silicon hardware — `racingTimeout` has zero
/// dependency on Containerization/VZ — so none of these guard on `ANGLESITE_CONTAINER_E2E`. They
/// still only build/run when this target is included at all (`ANGLESITE_CONTAINER_TESTS=1`), since
/// the target depends on `AnglesiteContainer`, which CI skips (`ANGLESITE_SKIP_CONTAINER=1`).
struct RacingTimeoutTests {
    private struct TestError: Error, Equatable {
        let message: String
    }

    @Test("a fast operation wins over the timeout")
    func fastOperationWins() async throws {
        let result = try await ContainerizationControl.racingTimeout(
            timeout: .seconds(30),
            timeoutError: TestError(message: "timed out")
        ) {
            "fast"
        }
        #expect(result == "fast")
    }

    @Test("a never-resolving operation times out")
    func neverResolvingOperationTimesOut() async throws {
        await #expect(throws: TestError.self) {
            try await ContainerizationControl.racingTimeout(
                timeout: .milliseconds(50),
                timeoutError: TestError(message: "timed out")
            ) {
                // Never returns within the test's lifetime — simulates a genuine VZ hang.
                try await Task.sleep(for: .seconds(3600))
                return "never"
            }
        }
    }

    @Test("a throwing operation propagates its own error, not the timeout error")
    func throwingOperationPropagates() async throws {
        await #expect(throws: TestError(message: "operation failed")) {
            try await ContainerizationControl.racingTimeout(
                timeout: .seconds(30),
                timeoutError: TestError(message: "timed out")
            ) {
                throw TestError(message: "operation failed")
            }
        }
    }

    @Test("a late success after the timeout already fired is reported via onLateSuccess, not thrown")
    func lateSuccessReportedNotThrown() async throws {
        let lateResult = LockedBox<String?>(nil)
        await #expect(throws: TestError.self) {
            try await ContainerizationControl.racingTimeout(
                timeout: .milliseconds(50),
                timeoutError: TestError(message: "timed out"),
                onLateSuccess: { value in lateResult.set(value) }
            ) {
                try await Task.sleep(for: .milliseconds(200))
                return "late"
            }
        }
        // Wait for the abandoned operation Task to finish and call onLateSuccess, rather than
        // guessing how long that takes after we've already received (and asserted) the timeout
        // error above.
        try await waitUntil("the abandoned operation to report its late success") {
            lateResult.get() != nil
        }
        #expect(lateResult.get() == "late")
    }
}

/// Minimal thread-safe box for reading a value set from a different Task than the one that reads
/// it — `Test`'s async body and the abandoned `racingTimeout` operation Task race independently.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }

    func set(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
