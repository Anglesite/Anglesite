import Testing
import Foundation
import AnglesiteTestSupport
@testable import AnglesiteCore

@Suite struct ACPContainerExecTransportTests {
    @Test func openInvokesExecInteractiveWithGivenCommand() async throws {
        let control = FakeLocalContainerControl(startResult: .success(LocalContainerSession(
            previewURL: URL(string: "http://127.0.0.1:1")!, mcpURL: URL(string: "http://127.0.0.1:2")!)))
        let transport = ACPContainerExecTransport(
            control: control, siteID: "site-1", command: "acp-agent", arguments: ["--flag"])
        try await transport.open()
        let calls = await control.execInteractiveCalls
        #expect(calls.count == 1)
        #expect(calls.first?.siteID == "site-1")
        #expect(calls.first?.argv == ["acp-agent", "--flag"])
        #expect(calls.first?.cwd == "/workspace/site")
    }

    @Test func sendWritesNewlineFramedJSONToTheHandle() async throws {
        let control = FakeLocalContainerControl(startResult: .success(LocalContainerSession(
            previewURL: URL(string: "http://127.0.0.1:1")!, mcpURL: URL(string: "http://127.0.0.1:2")!)))
        let transport = ACPContainerExecTransport(
            control: control, siteID: "site-1", command: "acp-agent", arguments: [])
        try await transport.open()
        try await transport.send(.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("initialize")]))
        let writes = await control.execInteractiveWrites
        #expect(writes.count == 1)
        let line = String(decoding: writes[0], as: UTF8.self)
        #expect(line.hasSuffix("\n"))
        #expect(line.contains("\"method\":\"initialize\""))
    }

    @Test func inboundParsesNewlineDelimitedJSONFromOnOutput() async throws {
        let message = #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#
        let control = FakeLocalContainerControl(
            startResult: .success(LocalContainerSession(
                previewURL: URL(string: "http://127.0.0.1:1")!, mcpURL: URL(string: "http://127.0.0.1:2")!)),
            execInteractiveStdoutLines: [message]
        )
        let transport = ACPContainerExecTransport(
            control: control, siteID: "site-1", command: "acp-agent", arguments: [])
        try await transport.open()
        var received: [JSONValue] = []
        for await value in transport.inbound() {
            received.append(value)
            break
        }
        #expect(received.count == 1)
        guard case .object(let obj) = received[0], case .int(1)? = obj["id"] else {
            Issue.record("expected the parsed initialize response")
            return
        }
    }
}
