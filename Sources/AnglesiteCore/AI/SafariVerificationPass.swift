import Foundation
// URLSession lives in FoundationNetworking on non-Darwin platforms (swift-corelibs-foundation);
// this import is a no-op on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Runs one headless, read-only Safari-backed inspection of a preview URL over the Safari MCP
/// bridge and returns a structured ``SafariVerificationReport`` — the `tools/call` follow-up to
/// #1910's `initialize`/`tools/list`-only ``SafariMCPBridgeClient``. Modeled on
/// `Sources/AnglesiteCore/Audit/AuditCommand.swift`: a one-shot actor that owns its own client,
/// runs, and always tears the client down. Ships no UI — the app-side surfacing
/// (`AuditModel`/`AuditSheetView`-style, per the `AuditCommand` → app two-layer pattern) is parent
/// issue #1911.
///
/// Wire-format assumption: each resolved tool returns its payload as a single `text` content
/// block — a JSON array string for the console/network tools, a plain string for the page-content
/// tool — or, for the screenshot tool, a single `image` content block. This mirrors how
/// `SafariMCPBridgeClient.callTool` already decodes MCP content blocks; there is no broader
/// `structuredContent` convention to lean on since #1887's transport spike only confirmed tool
/// *names*, not response shapes.
public actor SafariVerificationPass {
    /// Thrown when the pass cannot proceed at all: the navigate tool is missing from the
    /// server's `tools/list`, or the navigate call itself fails. Every other capability degrades
    /// to `.unavailable` instead of throwing (#1944's resolved default 3) — but a page that never
    /// loaded makes every other section meaningless, so navigation is the one exception.
    public enum PassError: Error, Sendable, Equatable {
        case navigateToolUnavailable
        case navigateFailed(String)
    }

    /// Ordered preferred tool names for each capability — first match against the server's
    /// `tools/list` catalog wins (#1944's resolved default 2). The transport spike confirmed
    /// `browser_console_messages` in the live catalog but didn't enumerate the rest, so this
    /// mapping is best-effort; a name not found there degrades its capability rather than failing
    /// the pass.
    private enum Capability {
        case navigate, console, network, pageContent, screenshot

        var preferredNames: [String] {
            switch self {
            case .navigate: return ["navigate_to_url"]
            case .console: return ["browser_console_messages"]
            case .network: return ["list_network_requests"]
            case .pageContent: return ["get_page_content"]
            case .screenshot: return ["screenshot"]
            }
        }
    }

    /// Cap on retained console/network entries per section (#1944's resolved default 6).
    private static let listCap = 200
    /// Cap on a retained screenshot payload, in bytes (#1944's resolved default 5).
    private static let screenshotByteCap = 8 * 1024 * 1024

    private let urlSession: URLSession
    private let logCenter: LogCenter

    /// `urlSession`/`logCenter` are injectable exactly like ``SafariMCPBridgeDetector``'s, so
    /// tests never touch the shared singletons.
    public init(urlSession: URLSession = .shared, logCenter: LogCenter = .shared) {
        self.urlSession = urlSession
        self.logCenter = logCenter
    }

    /// Constructs its own ``SafariMCPBridgeClient`` against `http://127.0.0.1:<port>/mcp`,
    /// connects, runs one pass against `previewURL`, and always closes the client before
    /// returning or throwing — mirroring ``SafariMCPBridgeDetector/checkReachability(port:timeout:)``.
    public func run(
        previewURL: URL,
        port: Int = SafariMCPBridgeDetector.defaultPort
    ) async throws -> SafariVerificationReport {
        let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp") ?? URL(string: "http://127.0.0.1/mcp")!
        let client = SafariMCPBridgeClient(endpoint: endpoint, urlSession: urlSession, logCenter: logCenter)
        do {
            _ = try await client.connect(timeout: NetworkTimeouts.safariMCPBridgeProbe)
        } catch {
            await client.close()
            throw error
        }
        do {
            let report = try await runPass(client: client, previewURL: previewURL)
            await client.close()
            return report
        } catch {
            await client.close()
            throw error
        }
    }

    // MARK: - Pass

    private func runPass(client: SafariMCPBridgeClient, previewURL: URL) async throws -> SafariVerificationReport {
        let tools = (try? await client.listTools()) ?? []
        let availableNames = Set(tools.map(\.name))
        func resolvedName(for capability: Capability) -> String? {
            capability.preferredNames.first { availableNames.contains($0) }
        }

        guard let navigateTool = resolvedName(for: .navigate) else {
            await log("navigate tool not found in tools/list — aborting pass", stream: .stderr)
            throw PassError.navigateToolUnavailable
        }
        do {
            _ = try await client.callTool(
                name: navigateTool,
                arguments: .object(["url": .string(previewURL.absoluteString)])
            )
        } catch {
            await log("navigate call failed: \(error)", stream: .stderr)
            throw PassError.navigateFailed("\(error)")
        }

        // Sequential, not concurrent: these tool calls drive one shared, stateful browser session
        // (the same tab the navigate call just loaded), so interleaving them could race against
        // the bridge in ways an audit report shouldn't depend on.
        let console = await fetchConsole(client: client, toolName: resolvedName(for: .console))
        let network = await fetchNetwork(client: client, toolName: resolvedName(for: .network))
        let pageContent = await fetchPageContent(client: client, toolName: resolvedName(for: .pageContent))
        let screenshot = await fetchScreenshot(client: client, toolName: resolvedName(for: .screenshot))

        return SafariVerificationReport(
            console: console,
            network: network,
            pageContent: pageContent,
            screenshot: screenshot
        )
    }

    // MARK: - Sections

    private func fetchConsole(
        client: SafariMCPBridgeClient,
        toolName: String?
    ) async -> SafariVerificationReport.Section<SafariVerificationReport.CappedList<SafariVerificationReport.ConsoleEntry>> {
        guard let toolName else {
            return .unavailable(reason: "no console tool found in tools/list")
        }
        do {
            let result = try await client.callTool(name: toolName)
            let entries = Self.decodeJSONArray(from: result).compactMap { entry -> SafariVerificationReport.ConsoleEntry? in
                guard case .object(let fields) = entry, case .string(let text)? = fields["text"] else { return nil }
                let level: String = { if case .string(let l)? = fields["level"] { return l }; return "log" }()
                return SafariVerificationReport.ConsoleEntry(level: level, text: text)
            }
            return .available(Self.cap(entries))
        } catch {
            return .unavailable(reason: "\(error)")
        }
    }

    private func fetchNetwork(
        client: SafariMCPBridgeClient,
        toolName: String?
    ) async -> SafariVerificationReport.Section<SafariVerificationReport.CappedList<SafariVerificationReport.NetworkEntry>> {
        guard let toolName else {
            return .unavailable(reason: "no network tool found in tools/list")
        }
        do {
            let result = try await client.callTool(name: toolName)
            let entries = Self.decodeJSONArray(from: result).compactMap { entry -> SafariVerificationReport.NetworkEntry? in
                guard case .object(let fields) = entry, case .string(let url)? = fields["url"] else { return nil }
                let method: String? = { if case .string(let m)? = fields["method"] { return m }; return nil }()
                let status: Int? = { if case .int(let s)? = fields["status"] { return s }; return nil }()
                let failed = status.map { $0 >= 400 } ?? true
                return SafariVerificationReport.NetworkEntry(url: url, method: method, status: status, failed: failed)
            }
            return .available(Self.cap(entries))
        } catch {
            return .unavailable(reason: "\(error)")
        }
    }

    private func fetchPageContent(
        client: SafariMCPBridgeClient,
        toolName: String?
    ) async -> SafariVerificationReport.Section<String> {
        guard let toolName else {
            return .unavailable(reason: "no page-content tool found in tools/list")
        }
        do {
            let result = try await client.callTool(name: toolName)
            guard let text = result.content.first(where: { $0.type == "text" })?.text else {
                return .unavailable(reason: "\(toolName) returned no text content")
            }
            return .available(text)
        } catch {
            return .unavailable(reason: "\(error)")
        }
    }

    private func fetchScreenshot(
        client: SafariMCPBridgeClient,
        toolName: String?
    ) async -> SafariVerificationReport.Section<Data> {
        guard let toolName else {
            return .unavailable(reason: "no screenshot tool found in tools/list")
        }
        do {
            let result = try await client.callTool(name: toolName)
            guard let image = result.content.first(where: { $0.type == "image" }),
                  let base64 = image.data,
                  let decoded = Data(base64Encoded: base64)
            else {
                return .unavailable(reason: "\(toolName) returned no image content")
            }
            guard decoded.count <= Self.screenshotByteCap else {
                await log(
                    "screenshot exceeded \(Self.screenshotByteCap)-byte cap (\(decoded.count) bytes) — dropped",
                    stream: .stderr
                )
                return .unavailable(reason: "screenshot exceeded \(Self.screenshotByteCap)-byte cap")
            }
            // Never log the base64 payload itself (#1944's resolved default 5) — only a one-line
            // summary, so the Debug pane stays readable.
            await log("screenshot captured (\(decoded.count) bytes)", stream: .stdout)
            return .available(decoded)
        } catch {
            return .unavailable(reason: "\(error)")
        }
    }

    // MARK: - Helpers

    private static func cap<Element: Sendable & Equatable>(
        _ entries: [Element]
    ) -> SafariVerificationReport.CappedList<Element> {
        SafariVerificationReport.CappedList(
            entries: Array(entries.prefix(listCap)),
            truncated: entries.count > listCap
        )
    }

    /// Decodes the first `text` content block as a JSON array, per this file's wire-format
    /// assumption. Returns `[]` for anything that doesn't parse — a malformed payload degrades to
    /// an empty list rather than throwing, matching this pass's overall degrade-don't-fail stance.
    private static func decodeJSONArray(from result: SafariMCPBridgeClient.ToolCallResult) -> [JSONValue] {
        guard let text = result.content.first(where: { $0.type == "text" })?.text,
              let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let array = raw as? [Any]
        else { return [] }
        return array.compactMap { JSONValue.from($0) }
    }

    private func log(_ text: String, stream: LogCenter.Stream) async {
        await logCenter.append(source: "safari-mcp", stream: stream, text: text)
    }
}
