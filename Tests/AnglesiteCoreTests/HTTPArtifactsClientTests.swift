import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct HTTPArtifactsClientTests {
    /// Scripted transport: returns `(data, status)` and records the request it saw.
    private final class Recorder: @unchecked Sendable {
        var request: URLRequest?
    }

    private func client(status: Int, json: String, recorder: Recorder? = nil) -> HTTPArtifactsClient {
        HTTPArtifactsClient(transport: { request in
            recorder?.request = request
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        })
    }

    @Test func createRepoSendsAuthorizedPOSTToAccountEndpoint() async throws {
        let recorder = Recorder()
        let ok = #"{"success":true,"errors":[],"result":{"name":"my-site"}}"#
        _ = try await client(status: 200, json: ok, recorder: recorder)
            .createRepo(name: "my-site", isPrivate: true, accountID: "acct123", token: "tok")
        let request = try #require(recorder.request)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString.hasSuffix("accounts/acct123/artifacts/repos") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        #expect(body?["name"] as? String == "my-site")
        #expect(body?["private"] as? Bool == true)
    }

    @Test func createRepoBuildsArtifactsRemoteRepo() async throws {
        let ok = #"{"success":true,"errors":[],"result":{"name":"my-site"}}"#
        let repo = try await client(status: 200, json: ok)
            .createRepo(name: "my-site", isPrivate: true, accountID: "acct123", token: "tok")
        #expect(repo.host == .cloudflareArtifacts)
        #expect(repo.owner == "acct123")
        #expect(repo.name == "my-site")
        #expect(repo.url == RepoHost.cloudflareArtifacts.browseURL(owner: "acct123", name: "my-site"))
    }

    @Test func createRepoMapsUnauthorized() async {
        await #expect(throws: ArtifactsAPIError.unauthorized(status: 403)) {
            _ = try await client(status: 403, json: "{}")
                .createRepo(name: "n", isPrivate: true, accountID: "a", token: "t")
        }
    }

    @Test func createRepoSurfacesAPIErrorMessage() async {
        let err = #"{"success":false,"errors":[{"code":1000,"message":"repository already exists"}],"result":null}"#
        await #expect(throws: ArtifactsAPIError.api(message: "repository already exists")) {
            _ = try await client(status: 200, json: err)
                .createRepo(name: "n", isPrivate: true, accountID: "a", token: "t")
        }
    }

    @Test func createRepoMapsHTTPFailure() async {
        await #expect(throws: ArtifactsAPIError.http(status: 500)) {
            _ = try await client(status: 500, json: "oops")
                .createRepo(name: "n", isPrivate: true, accountID: "a", token: "t")
        }
    }

    @Test func createRepoMapsTransportFailureToNetwork() async {
        let failing = HTTPArtifactsClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: ArtifactsAPIError.network) {
            _ = try await failing.createRepo(name: "n", isPrivate: true, accountID: "a", token: "t")
        }
    }

    @Test func probeAvailabilityTrueOnSuccessEnvelope() async {
        let ok = #"{"success":true,"errors":[],"result":[]}"#
        let available = await client(status: 200, json: ok)
            .probeAvailability(accountID: "acct123", token: "tok")
        #expect(available)
    }

    @Test func probeAvailabilityFalseWithoutBetaAccess() async {
        // 404 = endpoint unknown to this account (no beta); must NOT read as available,
        // unlike CloudflareCapabilityProber's permissive not-401/403 semantics.
        let unavailable404 = await client(status: 404, json: "{}")
            .probeAvailability(accountID: "acct123", token: "tok")
        #expect(unavailable404 == false)
        let unavailable403 = await client(status: 403, json: "{}")
            .probeAvailability(accountID: "acct123", token: "tok")
        #expect(unavailable403 == false)
    }

    @Test func probeAvailabilityFalseOnTransportFailure() async {
        let failing = HTTPArtifactsClient(transport: { _ in throw URLError(.timedOut) })
        let available = await failing.probeAvailability(accountID: "a", token: "t")
        #expect(available == false)
    }
}
