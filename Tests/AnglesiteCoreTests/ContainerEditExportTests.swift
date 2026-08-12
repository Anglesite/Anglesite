import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct ContainerEditExportTests {
    @Test func isPlausibleCommitAcceptsSevenToSixtyFourHexChars() {
        #expect(ContainerEditExport.isPlausibleCommit("abc1234"))
        #expect(ContainerEditExport.isPlausibleCommit(String(repeating: "a", count: 64)))
        #expect(!ContainerEditExport.isPlausibleCommit("abc123")) // 6 chars, too short
        #expect(!ContainerEditExport.isPlausibleCommit(String(repeating: "a", count: 65))) // too long
        #expect(!ContainerEditExport.isPlausibleCommit("not-hex!"))
    }

    /// A `LocalContainerControl` fake whose `exec` returns a canned export-script result instead
    /// of running a real container — this suite never boots anything.
    actor ScriptedControl: LocalContainerControl {
        private let result: Result<ContainerExecResult, Error>
        private(set) var lastArgv: [String]?
        init(result: Result<ContainerExecResult, Error>) { self.result = result }
        func start(siteID: String, sourceRepo: URL, ref: String, onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void) async throws -> LocalContainerSession {
            fatalError("not exercised by this suite")
        }
        func stop(siteID: String) async throws {}
        func exec(siteID: String, argv: [String], environment: [String: String], workingDirectory: String, onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void) async throws -> ContainerExecResult {
            lastArgv = argv
            return try result.get()
        }
        func execInteractive(siteID: String, argv: [String], environment: [String: String], workingDirectory: String, onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void) async throws -> InteractiveExecHandle {
            InteractiveExecHandle(write: { _ in }, terminate: {})
        }
        func startWorkersDev(siteID: String, workers: [WorkerDescriptor], onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void) async throws -> URL {
            URL(string: "http://127.0.0.1:1")!
        }
        func stopWorkersDev(siteID: String) async throws {}
    }

    @Test func exportAndImportCallsImportBundleWithParsedCommitAndBundleBytes() async throws {
        let bundleBytes = Data("bundle-bytes".utf8)
        let stdout = "abcdef0123456789abcdef0123456789abcdef01\n" + bundleBytes.base64EncodedString()
        let control = ScriptedControl(result: .success(ContainerExecResult(exitCode: 0, stdout: stdout, stderr: "")))
        var imported: (bundle: URL, commit: String, source: URL)?
        var loggedLines: [(String, LogCenter.Stream)] = []

        try await ContainerEditExport.exportAndImport(
            commit: "abcdef0",
            siteID: "site-1",
            control: control,
            sourceDirectory: URL(fileURLWithPath: "/tmp/source"),
            onLog: { line, stream in loggedLines.append((line, stream)) },
            importBundle: { (bundle: URL, commit: String, source: URL) async throws -> Void in
                imported = (bundle, commit, source)
                #expect(try Data(contentsOf: bundle) == bundleBytes)
            }
        )

        #expect(imported?.commit == "abcdef0123456789abcdef0123456789abcdef01")
        #expect(imported?.source == URL(fileURLWithPath: "/tmp/source"))
        #expect(loggedLines.contains { $0.0.contains("persisted") && $0.1 == .stdout })
        #expect(await control.lastArgv?.contains("abcdef0") == true)
    }

    @Test func exportAndImportThrowsOnNonZeroExit() async {
        let control = ScriptedControl(result: .success(ContainerExecResult(exitCode: 1, stdout: "", stderr: "boom")))
        await #expect(throws: SiteRuntimePersistenceError.self) {
            try await ContainerEditExport.exportAndImport(
                commit: "abcdef0", siteID: "site-1", control: control,
                sourceDirectory: URL(fileURLWithPath: "/tmp/source"),
                onLog: { _, _ in }, importBundle: { _, _, _ in Issue.record("must not import on exec failure") })
        }
    }

    @Test func exportAndImportThrowsOnMalformedStdout() async {
        let control = ScriptedControl(result: .success(ContainerExecResult(exitCode: 0, stdout: "only-one-line", stderr: "")))
        await #expect(throws: SiteRuntimePersistenceError.self) {
            try await ContainerEditExport.exportAndImport(
                commit: "abcdef0", siteID: "site-1", control: control,
                sourceDirectory: URL(fileURLWithPath: "/tmp/source"),
                onLog: { _, _ in }, importBundle: { _, _, _ in Issue.record("must not import on malformed stdout") })
        }
    }

    @Test func exportAndImportLogsAndRethrowsWhenImportBundleFails() async {
        let stdout = "abcdef0123456789abcdef0123456789abcdef01\n" + Data("x".utf8).base64EncodedString()
        let control = ScriptedControl(result: .success(ContainerExecResult(exitCode: 0, stdout: stdout, stderr: "")))
        var loggedLines: [(String, LogCenter.Stream)] = []
        await #expect(throws: SiteRuntimePersistenceError.self) {
            try await ContainerEditExport.exportAndImport(
                commit: "abcdef0", siteID: "site-1", control: control,
                sourceDirectory: URL(fileURLWithPath: "/tmp/source"),
                onLog: { line, stream in loggedLines.append((line, stream)) },
                importBundle: { _, _, _ in throw SiteRuntimePersistenceError.syncFailed("nope") })
        }
        #expect(loggedLines.contains { $0.0.contains("persist failed") && $0.1 == .stderr })
    }
}
