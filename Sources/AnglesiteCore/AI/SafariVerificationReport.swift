import Foundation

/// Structured output of one ``SafariVerificationPass`` run. Modeled on ``AuditReport``: each
/// section is independently either present or degraded to `.unavailable(reason:)` — a capability
/// whose tool is missing from `tools/list`, or whose call fails, never fails the whole pass (see
/// #1944's resolved default 3). The only section that isn't representable here as `.unavailable`
/// is navigation itself — a failed navigate throws out of ``SafariVerificationPass/run(previewURL:port:connectTimeout:)``
/// entirely, since every other section would be meaningless against an unknown page.
public struct SafariVerificationReport: Sendable, Equatable {
    /// One report section: present with a decoded payload, or degraded with a human-readable
    /// reason (a missing tool, a thrown `tools/call`, or a value that failed validation).
    public enum Section<Value: Sendable & Equatable>: Sendable, Equatable {
        case available(Value)
        case unavailable(reason: String)
    }

    /// A capped list plus whether the underlying tool reported more entries than were retained
    /// (#1944's resolved default 6 — console/network entries are each capped at 200).
    public struct CappedList<Element: Sendable & Equatable>: Sendable, Equatable {
        public let entries: [Element]
        public let truncated: Bool

        public init(entries: [Element], truncated: Bool) {
            self.entries = entries
            self.truncated = truncated
        }
    }

    /// One console message, as reported by the resolved console tool (preferred name
    /// `browser_console_messages`). `level` is kept as the tool's own string (e.g. `"error"`,
    /// `"warning"`, `"log"`) rather than a closed enum — the pass doesn't hard-code the bridge's
    /// vocabulary — so a caller can filter to errors by string comparison.
    public struct ConsoleEntry: Sendable, Equatable {
        public let level: String
        public let text: String

        public init(level: String, text: String) {
            self.level = level
            self.text = text
        }
    }

    /// One network request, as reported by the resolved network tool (preferred name
    /// `list_network_requests`).
    public struct NetworkEntry: Sendable, Equatable {
        public let url: String
        public let method: String?
        public let status: Int?
        /// Whether this request should be treated as a failure — a missing status (the request
        /// never completed) or a >= 400 status. Computed once here so callers don't reimplement
        /// the rule themselves.
        public let failed: Bool

        public init(url: String, method: String?, status: Int?, failed: Bool) {
            self.url = url
            self.method = method
            self.status = status
            self.failed = failed
        }
    }

    /// Console messages captured during the pass, or why they weren't.
    public let console: Section<CappedList<ConsoleEntry>>
    /// Network requests observed during the pass, or why they weren't.
    public let network: Section<CappedList<NetworkEntry>>
    /// A page-content summary (the resolved `get_page_content`-style tool's text output), or why
    /// there isn't one.
    public let pageContent: Section<String>
    /// The captured screenshot's decoded image data, or why there isn't one — including a payload
    /// over the 8 MiB cap (#1944's resolved default 5), which is dropped rather than retained.
    public let screenshot: Section<Data>

    /// Memberwise; assembled by `SafariVerificationPass.run(previewURL:port:connectTimeout:)` in production,
    /// directly by tests.
    public init(
        console: Section<CappedList<ConsoleEntry>>,
        network: Section<CappedList<NetworkEntry>>,
        pageContent: Section<String>,
        screenshot: Section<Data>
    ) {
        self.console = console
        self.network = network
        self.pageContent = pageContent
        self.screenshot = screenshot
    }
}
