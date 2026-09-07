import Foundation
import Testing
@testable import AnglesiteContainer

// On a stock toolchain, `swift test` cannot grant `com.apple.security.virtualization` to its own
// runner — use `scripts/run-container-probe.sh echo` to run this same round-trip entitled.

/// Minimal synthetic repro for the #69 vsock handshake mystery: no git, no npm, no astro —
/// one guest socat echo listener on an AF_VSOCK port, one host dialVsock, assert bytes
/// round-trip. If THIS fails, the bug is in the framework/kernel vsock path and this file
/// is the upstream repro; if it passes, the failure lives in Anglesite's full boot flow.
///
/// Local-only, entitlement-gated: this whole *target* is excluded from CI's `swift test` (see
/// `ContainerizationControlTests`'s header), and this test body additionally requires
/// `ANGLESITE_CONTAINER_E2E=1` so it only runs when explicitly invoked on an entitled
/// Apple-Silicon Mac with the vendored boot artifacts present.
@Suite struct VsockEchoEndToEndTests {
    private var enabled: Bool {
        ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_E2E"] == "1"
    }

    @Test("host dialVsock reaches a guest vsock listener and bytes round-trip")
    func vsockEchoRoundTrip() async throws {
        try #require(enabled, "set ANGLESITE_CONTAINER_E2E=1 on an entitled Apple-Silicon Mac")

        let control = ContainerizationControl()
        let container = try await control.makeBareContainer(siteID: "vsock-echo-e2e")
        do {
            try await control.runDetached(container, id: "echo", label: "echo", onOutput: { line, _ in
                FileHandle.standardError.write(Data("[echo] \(line)\n".utf8))
            }, ["/usr/bin/socat", "VSOCK-LISTEN:9999,reuseaddr,fork", "EXEC:cat"])

            // Retry the dial until the listener is up (socat needs a beat to bind).
            var handle: FileHandle?
            var lastError: Error?
            for _ in 0..<40 {
                do {
                    handle = try await container.dialVsock(port: 9999)
                    break
                } catch {
                    lastError = error
                    try await Task.sleep(for: .milliseconds(250)) // sleep-is-subject: real vsock dial retry against a live guest, no completion event to await
                }
            }
            let fh = try #require(
                handle,
                "never dialed guest vsock :9999 within 10s; last error: \(String(describing: lastError))")

            let payload = Data("ping-vsock-echo\n".utf8)
            try fh.write(contentsOf: payload)

            // Read until the payload echoes back (or 10s deadline).
            var received = Data()
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while received.count < payload.count, ContinuousClock.now < deadline {
                let chunk = fh.availableData
                if chunk.isEmpty {
                    try await Task.sleep(for: .milliseconds(100)) // sleep-is-subject: real raw-socket read poll against a live guest, no completion event to await
                } else {
                    received.append(chunk)
                }
            }
            #expect(received == payload,
                "echo mismatch: got \(received.count) bytes — the dial-ok/instant-EOF signature means the vsock data path is broken at the framework layer")
            try? fh.close()
        } catch {
            await control.stopBareContainer(container, siteID: "vsock-echo-e2e")
            throw error
        }
        await control.stopBareContainer(container, siteID: "vsock-echo-e2e")
    }
}
