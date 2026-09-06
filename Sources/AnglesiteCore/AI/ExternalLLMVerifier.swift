import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Outcome of verifying a user-configured external LLM endpoint. Core-level and UI-free by
/// design (#1907): `SettingsView` maps this to `KeychainTokenRow.VerifyOutcome`, which stays an
/// App-side UI type.
public enum ExternalLLMVerifyResult: Sendable, Equatable {
    /// The endpoint responded with a 2xx status. `detail` is a `"<n> model(s) available"`
    /// string derived from a `{"data": [...]}` response body, or `nil` when the body doesn't
    /// parse into that shape (still a successful connection).
    case success(detail: String?)
    case failure(String)
}

/// GETs `{baseURL}/models` — the OpenAI-compatible endpoint every mainstream provider and
/// self-hosted server (OpenAI, Groq, vLLM, Ollama, LM Studio) implements — to confirm a
/// user-configured external LLM endpoint and API key work before `ExternalLLMBackend` starts a
/// chat against them. Extracted from `SettingsView.verifyExternalLLMEndpoint` (#1907, step 3 of
/// #1818's owner-approved plan) so the network call and byte-capped read are testable without a
/// view. Deliberately free of `AppSettings` side effects — the caller persists
/// `externalLLMVerifiedBaseURL`/`Detail` after a successful verify — so this type stays testable
/// in isolation.
public struct ExternalLLMVerifier: Sendable {
    /// Upper bound on the `/models` response body this reads while verifying — the same
    /// user-supplied-endpoint threat model `ExternalLLMBackend`'s SSE draining guards against
    /// (a typo'd URL, a hostile host, or a plain never-ending response can all reach here), so
    /// this read is bounded rather than trusted like an unbounded read would be (#1482 review).
    /// Generous for a real `/models` list — the far side of this limit only ever costs the
    /// cosmetic model-count `detail`, never verification success itself.
    static let verifyResponseByteLimit = 65_536

    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// A 2xx response whose body parses as `{"data": [...]}` (the OpenAI list shape) reports a
    /// model count; a 2xx response in any other shape still counts as a successful connection.
    public func verify(baseURLText: String, apiKey: String) async -> ExternalLLMVerifyResult {
        let trimmed = baseURLText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, var base = URL(string: trimmed) else {
            return .failure("enter a base URL first")
        }
        if base.absoluteString.hasSuffix("/") {
            guard let trimmedBase = URL(string: String(base.absoluteString.dropLast())) else {
                return .failure("enter a base URL first")
            }
            base = trimmedBase
        }
        guard let url = URL(string: base.absoluteString + "/models") else {
            return .failure("enter a base URL first")
        }
        var request = URLRequest(url: url)
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }

#if canImport(Darwin)
        do {
            let (asyncBytes, response) = try await urlSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                asyncBytes.task.cancel()
                return .failure("no HTTP response")
            }
            guard (200...299).contains(http.statusCode) else {
                asyncBytes.task.cancel()
                return .failure("HTTP \(http.statusCode)")
            }
            var data = Data()
            for try await byte in asyncBytes {
                data.append(byte)
                if data.count >= Self.verifyResponseByteLimit { break }
            }
            // Stop the rest of a large or never-ending body from continuing to arrive into a
            // stream nothing reads — a no-op if it already finished on its own (#1482 review).
            asyncBytes.task.cancel()
            return .success(detail: Self.modelCountDetail(from: data))
        } catch {
            return .failure(error.localizedDescription)
        }
#else
        // `FoundationNetworking` has no `URLSession.bytes(for:)`/`AsyncBytes` — `HTTPStreamingRunner`
        // is the off-Darwin replacement `ExternalLLMBackend` already uses for the same reason.
        let runner = HTTPStreamingRunner()
        do {
            let response = try await runner.start(request, configuration: urlSession.configuration)
            guard let http = response as? HTTPURLResponse else {
                runner.cancel()
                return .failure("no HTTP response")
            }
            guard (200...299).contains(http.statusCode) else {
                runner.cancel()
                return .failure("HTTP \(http.statusCode)")
            }
            var data = Data()
            for try await chunk in runner.bodyStream {
                data.append(chunk)
                if data.count >= Self.verifyResponseByteLimit { break }
            }
            runner.cancel()
            return .success(detail: Self.modelCountDetail(from: data))
        } catch {
            runner.cancel()
            return .failure(error.localizedDescription)
        }
#endif
    }

    private static func modelCountDetail(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [Any] else { return nil }
        return "\(models.count) model\(models.count == 1 ? "" : "s") available"
    }
}
