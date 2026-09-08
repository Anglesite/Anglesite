import Foundation
import Testing
@testable import AnglesiteAppCore

/// `ContinuationGate` is the resume-at-most-once + cancellation seam the Cloudflare OAuth
/// presenter (`CloudflareOAuthSignIn.defaultPresenter`) sits on. The real presenter can't run
/// headlessly (it needs `AuthenticationServices` UI), so the plumbing that decides *whether the
/// continuation ever resumes* is tested here on its own — that plumbing is exactly what #1951
/// (a session that never reports back) and #1766 (a session that reports back twice) hinge on.
@Suite("ContinuationGate", .timeLimit(.minutes(1)))
struct ContinuationGateTests {
    struct Boom: Error {}

    @Test("the first finish resumes the continuation; a second is ignored")
    func finishResumesOnce() async throws {
        let gate = ContinuationGate<Int>()
        let value = try await withCheckedThrowingContinuation { continuation in
            gate.attach(continuation)
            let first = gate.finish(.success(1))
            let second = gate.finish(.success(2))
            #expect(first)
            #expect(!second)
        }
        #expect(value == 1)
    }

    @Test("a result delivered before attach resumes the continuation on attach")
    func finishBeforeAttachIsDeliveredOnAttach() async throws {
        let gate = ContinuationGate<Int>()
        #expect(gate.finish(.success(7)))
        let value = try await withCheckedThrowingContinuation { continuation in
            gate.attach(continuation)
        }
        #expect(value == 7)
    }

    @Test("cancel resumes a pending continuation with CancellationError and runs the cancel handler once")
    func cancelResumesWithCancellationError() async {
        let gate = ContinuationGate<Int>()
        let tearDowns = Counter()
        gate.setCancelHandler { tearDowns.increment() }
        await #expect(throws: CancellationError.self) {
            try await withCheckedThrowingContinuation { continuation in
                gate.attach(continuation)
                gate.cancel()
                gate.cancel()
            }
        }
        #expect(tearDowns.value == 1)
        // The session reporting back after it was cancelled must not resume a second time.
        #expect(!gate.finish(.failure(Boom())))
    }

    @Test("cancel before attach resumes the continuation with CancellationError on attach")
    func cancelBeforeAttach() async {
        let gate = ContinuationGate<Int>()
        gate.cancel()
        await #expect(throws: CancellationError.self) {
            try await withCheckedThrowingContinuation { continuation in
                gate.attach(continuation)
            }
        }
    }

    @Test("a cancel handler installed after cancel runs immediately")
    func lateCancelHandlerRunsImmediately() {
        let gate = ContinuationGate<Int>()
        let tearDowns = Counter()
        gate.cancel()
        gate.setCancelHandler { tearDowns.increment() }
        #expect(tearDowns.value == 1)
    }

    @Test("a cancel after finish is a no-op and doesn't run the cancel handler")
    func cancelAfterFinishIsIgnored() async throws {
        let gate = ContinuationGate<Int>()
        let tearDowns = Counter()
        gate.setCancelHandler { tearDowns.increment() }
        let value = try await withCheckedThrowingContinuation { continuation in
            gate.attach(continuation)
            gate.finish(.success(3))
            gate.cancel()
        }
        #expect(value == 3)
        #expect(tearDowns.value == 0)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
