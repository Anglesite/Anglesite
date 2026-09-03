import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A fake `@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)` transport — the shape
/// shared by every ActivityPub/Lemmy federation client's `Transport` typealias
/// (`CommunityActorResolver`, `CommunitySearchClient`, `GroupTimelineClient`,
/// `CommunityMembershipClient`, `ActivityPubFollowersClient`), so one fake serves them all. An
/// `actor` rather than an `@unchecked Sendable` class: the recording state is mutated from the
/// `@Sendable` transport closure, so it needs real isolation, not just a promise that callers
/// won't race it.
///
/// Two constructors cover the two response shapes tests need:
///  - ``init(_:)`` routes each request by its exact URL to a canned `(status, body)`, falling
///    back to 404 for anything unmatched — for a test exercising several distinct endpoints
///    (webfinger + actor document, outbox POST + GET, …).
///  - ``init(status:body:)`` answers every request the same way, regardless of URL — for a test
///    exercising a single endpoint.
///  - ``init(throwing:)`` simulates a network-level failure with no HTTP response at all (DNS
///    failure, no connectivity, …).
public actor FakeTransport {
    private let responses: [String: (status: Int, body: String)]
    private let defaultStatus: Int
    private let defaultBody: String
    private let error: (any Error)?

    public private(set) var requestedURLs: [URL] = []
    public private(set) var requestedHeaders: [[String: String]] = []
    public private(set) var requestedBodies: [[String: Any]] = []
    public private(set) var requestedTimeouts: [TimeInterval] = []

    /// URLs whose response is held back until `release(_:)` is called — lets a test hold one
    /// request open while it observes or triggers other model behavior.
    private var gatedURLs: Set<String> = []
    private var gateContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var arrivedURLs: Set<String> = []
    private var arrivalContinuations: [String: CheckedContinuation<Void, Never>] = [:]

    /// Routes each requested URL to a canned `(status, body)`; unmatched URLs 404.
    public init(_ responses: [String: (status: Int, body: String)]) {
        self.responses = responses
        self.defaultStatus = 404
        self.defaultBody = "not found"
        self.error = nil
    }

    /// Answers every request with the same canned `(status, body)`, regardless of URL.
    public init(status: Int = 200, body: String = "{}") {
        self.responses = [:]
        self.defaultStatus = status
        self.defaultBody = body
        self.error = nil
    }

    /// Simulates a network-level failure with no HTTP response at all — the branch a client's
    /// transport call re-wraps as its own "request failed" error.
    public init(throwing error: any Error) {
        self.responses = [:]
        self.defaultStatus = 0
        self.defaultBody = ""
        self.error = error
    }

    public func gate(_ url: String) { gatedURLs.insert(url) }

    /// Releases a gated URL, letting its held-open request return.
    public func release(_ url: String) {
        gatedURLs.remove(url)
        gateContinuations.removeValue(forKey: url)?.resume()
    }

    /// Suspends until `url` has been requested at least once — so a test can synchronize on
    /// "the gated request is now in flight" without racing the `Task` that issues it.
    public func waitUntilRequested(_ url: String) async {
        if arrivedURLs.contains(url) { return }
        await withCheckedContinuation { continuation in
            arrivalContinuations[url] = continuation
        }
    }

    private func waitIfGated(_ url: String) async {
        guard gatedURLs.contains(url) else { return }
        await withCheckedContinuation { continuation in
            gateContinuations[url] = continuation
        }
    }

    private func respond(to request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let error { throw error }
        let url = request.url!
        requestedURLs.append(url)
        requestedHeaders.append(request.allHTTPHeaderFields ?? [:])
        requestedTimeouts.append(request.timeoutInterval)
        if let bodyData = request.httpBody,
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            requestedBodies.append(json)
        }
        arrivedURLs.insert(url.absoluteString)
        arrivalContinuations.removeValue(forKey: url.absoluteString)?.resume()
        await waitIfGated(url.absoluteString)
        let (status, body) = responses[url.absoluteString] ?? (defaultStatus, defaultBody)
        let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), http)
    }

    public nonisolated var transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        { request in try await self.respond(to: request) }
    }
}
