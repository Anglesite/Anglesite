import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteAppCore

private actor StubPass: SafariVerifying {
    private let result: Result<SafariVerificationReport, Error>
    private(set) var capturedPreviewURL: URL?
    private(set) var capturedPort: Int?

    init(result: Result<SafariVerificationReport, Error>) {
        self.result = result
    }

    func run(previewURL: URL, port: Int, connectTimeout: TimeInterval) async throws -> SafariVerificationReport {
        capturedPreviewURL = previewURL
        capturedPort = port
        return try result.get()
    }
}

private let sampleReport = SafariVerificationReport(
    console: .available(.init(entries: [.init(level: "error", text: "boom")], truncated: false)),
    network: .available(.init(entries: [], truncated: false)),
    pageContent: .available("<html></html>"),
    screenshot: .unavailable(reason: "no screenshot tool found in tools/list")
)

/// `.timeLimit`: mirrors `AgentReadinessModelTests` — a wedged run fails fast as a time-limit
/// violation instead of hanging the suite under machine contention (#1349).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SafariVerificationModelTests {
    @MainActor
    @Test("run(previewURL:) fails clearly when there's no live preview URL")
    func runNoPreviewURL() async {
        let model = SafariVerificationModel(pass: StubPass(result: .success(sampleReport)), portProvider: { 9222 })
        model.run(previewURL: nil)
        guard case .failed(let reason) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(reason.contains("Start the preview"))
    }

    @MainActor
    @Test("run(previewURL:) submits the given URL and configured port, and surfaces the report")
    func runSucceeds() async throws {
        let stub = StubPass(result: .success(sampleReport))
        let model = SafariVerificationModel(pass: stub, portProvider: { 9222 })
        let url = try #require(URL(string: "http://localhost:4321/"))

        model.run(previewURL: url)
        while model.isRunning { await Task.yield() }

        let capturedURL = await stub.capturedPreviewURL
        let capturedPort = await stub.capturedPort
        #expect(capturedURL == url)
        #expect(capturedPort == 9222)
        guard case .succeeded(let report, let previewURL) = model.phase else {
            Issue.record("expected .succeeded, got \(model.phase)")
            return
        }
        #expect(report == sampleReport)
        #expect(previewURL == url)
    }

    @MainActor
    @Test("run(previewURL:) surfaces a navigateFailed PassError with a readable reason")
    func runNavigateFailed() async throws {
        let stub = StubPass(result: .failure(SafariVerificationPass.PassError.navigateFailed("connection refused")))
        let model = SafariVerificationModel(pass: stub, portProvider: { 9222 })
        let url = try #require(URL(string: "http://localhost:4321/"))

        model.run(previewURL: url)
        while model.isRunning { await Task.yield() }

        guard case .failed(let reason) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(reason.contains("connection refused"))
    }

    @MainActor
    @Test("run(previewURL:) surfaces a navigateToolUnavailable PassError with a readable reason")
    func runNavigateToolUnavailable() async throws {
        let stub = StubPass(result: .failure(SafariVerificationPass.PassError.navigateToolUnavailable))
        let model = SafariVerificationModel(pass: stub, portProvider: { 9222 })
        let url = try #require(URL(string: "http://localhost:4321/"))

        model.run(previewURL: url)
        while model.isRunning { await Task.yield() }

        guard case .failed(let reason) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(reason.contains("preview page"))
    }

    @MainActor
    @Test("openSheet() resets phase and presents")
    func openSheetResets() {
        let model = SafariVerificationModel(pass: StubPass(result: .success(sampleReport)), portProvider: { 9222 })
        model.openSheet()
        #expect(model.sheetPresented == true)
        #expect(model.phase == .idle)
    }

    @MainActor
    @Test("dismissSheet() clears the presented flag")
    func dismissSheetClearsPresented() {
        let model = SafariVerificationModel(pass: StubPass(result: .success(sampleReport)), portProvider: { 9222 })
        model.openSheet()
        model.dismissSheet()
        #expect(model.sheetPresented == false)
    }
}
