import Foundation
import Testing
@testable import Recallyx
@testable import RecallyxCore

/// Hermetic HTTP seam: records every request and answers from a handler.
private final class FakeHTTP: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { _requests } }
    let handler: @Sendable (URLRequest) throws -> (Int, String)

    init(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, String)) { self.handler = handler }

    var get: ModelListService.HTTPGet {
        { [self] request in
            lock.withLock { _requests.append(request) }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }
}

private func query(_ request: URLRequest, _ name: String) -> String? {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == name }?.value
}

@Suite("ModelListService")
struct ModelListServiceTests {
    @Test func openAISendsBearerAndFilters() async throws {
        let http = FakeHTTP { _ in
            (200, #"{"data":[{"id":"gpt-5.4-mini"},{"id":"text-embedding-3-small"},{"id":"whisper-1"}]}"#)
        }
        let service = ModelListService(readKey: { _ in "sk-test" }, get: http.get)
        let result = await service.fetchModels(for: ProviderConfig(type: .openai))
        #expect(try result.get() == ["gpt-5.4-mini"])
        let req = try #require(http.requests.first)
        #expect(req.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    }

    @Test func missingKeyMakesNoRequest() async {
        let http = FakeHTTP { _ in (200, "{}") }
        let service = ModelListService(readKey: { _ in nil }, get: http.get)
        for type in [ProviderType.openai, .anthropic, .gemini] {
            let result = await service.fetchModels(for: ProviderConfig(type: type))
            #expect(result == .failure(.missingKey))
        }
        #expect(http.requests.isEmpty)
    }

    @Test func anthropicPaginatesViaAfterID() async throws {
        let http = FakeHTTP { req in
            if query(req, "after_id") == nil {
                return (200, #"{"data":[{"id":"claude-a"},{"id":"claude-b"}],"has_more":true,"last_id":"claude-b"}"#)
            }
            #expect(query(req, "after_id") == "claude-b")
            return (200, #"{"data":[{"id":"claude-c"}],"has_more":false,"last_id":"claude-c"}"#)
        }
        let service = ModelListService(readKey: { _ in "sk-ant" }, get: http.get)
        let result = await service.fetchModels(for: ProviderConfig(type: .anthropic))
        #expect(try result.get() == ["claude-a", "claude-b", "claude-c"])
        #expect(http.requests.count == 2)
        let first = http.requests[0]
        #expect(first.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(first.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test func geminiPaginatesViaPageTokenAndFilters() async throws {
        let http = FakeHTTP { req in
            #expect(query(req, "key") == "AIza")
            if query(req, "pageToken") == nil {
                return (200, #"{"models":[{"name":"models/gemini-x","supportedGenerationMethods":["generateContent"]},{"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"p2"}"#)
            }
            #expect(query(req, "pageToken") == "p2")
            return (200, #"{"models":[{"name":"models/gemini-y","supportedGenerationMethods":["generateContent","countTokens"]}]}"#)
        }
        let service = ModelListService(readKey: { _ in "AIza" }, get: http.get)
        let result = await service.fetchModels(for: ProviderConfig(type: .gemini))
        #expect(try result.get() == ["gemini-x", "gemini-y"])
        #expect(http.requests.count == 2)
    }

    @Test func paginationIsBounded() async {
        let http = FakeHTTP { _ in
            (200, #"{"data":[{"id":"claude-loop"}],"has_more":true,"last_id":"claude-loop"}"#)
        }
        let service = ModelListService(readKey: { _ in "k" }, get: http.get)
        _ = await service.fetchModels(for: ProviderConfig(type: .anthropic))
        #expect(http.requests.count == ModelListService.maxPages)
    }

    @Test func ollamaListsInstalledTagsWithoutKey() async throws {
        let http = FakeHTTP { _ in (200, #"{"models":[{"name":"llama3.2:latest"},{"name":"llava:13b"}]}"#) }
        let service = ModelListService(readKey: { _ in nil }, get: http.get)
        let result = await service.fetchModels(for: ProviderConfig(type: .ollama, baseURL: "http://localhost:11434/"))
        #expect(try result.get() == ["llama3.2:latest", "llava:13b"])
        #expect(http.requests.first?.url?.absoluteString == "http://localhost:11434/api/tags")
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func customEndpointUsesBaseURLAndDenylistOnly() async throws {
        let http = FakeHTTP { _ in
            (200, #"{"data":[{"id":"mixtral-8x7b"},{"id":"llama-3.1-70b"},{"id":"nomic-embed-text"},{"id":"bge-reranker"}]}"#)
        }
        let service = ModelListService(readKey: { _ in "" }, get: http.get)
        let p = ProviderConfig(type: .openAICompatible, baseURL: "https://api.groq.com/openai/v1")
        let result = await service.fetchModels(for: p)
        // Non-gpt ids survive (no OpenAI allowlist); alphabetical.
        #expect(try result.get() == ["llama-3.1-70b", "mixtral-8x7b"])
        #expect(http.requests.first?.url?.absoluteString == "https://api.groq.com/openai/v1/models")
        // Keyless local servers: no Authorization header.
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func customWithoutBaseURLFails() async {
        let service = ModelListService(readKey: { _ in "k" }, get: FakeHTTP { _ in (200, "{}") }.get)
        #expect(await service.fetchModels(for: ProviderConfig(type: .openAICompatible)) == .failure(.missingBaseURL))
    }

    @Test func errorMapping() async {
        func run(_ status: Int, _ body: String = "{}") async -> Result<[String], ModelFetchError> {
            let service = ModelListService(readKey: { _ in "k" }, get: FakeHTTP { _ in (status, body) }.get)
            return await service.fetchModels(for: ProviderConfig(type: .openai))
        }
        #expect(await run(401) == .failure(.unauthorized))
        #expect(await run(403) == .failure(.unauthorized))
        #expect(await run(500) == .failure(.http(500)))
        #expect(await run(200, "<html>") == .failure(.unparseable))
        #expect(await run(200, #"{"data":[{"id":"whisper-1"}]}"#) == .failure(.empty))

        let offline = ModelListService(readKey: { _ in "k" }, get: FakeHTTP { _ in throw URLError(.notConnectedToInternet) }.get)
        #expect(await offline.fetchModels(for: ProviderConfig(type: .ollama)) == .failure(.network))
    }

    @Test func appleIsNotFetchable() async {
        let http = FakeHTTP { _ in (200, "{}") }
        let service = ModelListService(readKey: { _ in nil }, get: http.get)
        #expect(await service.fetchModels(for: ProviderConfig(type: .apple)) == .failure(.notFetchable))
        #expect(http.requests.isEmpty)
    }

    @Test func errorCategoriesAreContentFree() {
        #expect(ModelFetchError.http(502).category == "http502")
        #expect(ModelFetchError.unauthorized.category == "unauthorized")
    }

    // MARK: - Custom-provider model merge (Providers tab "Add from server")

    @Test func mergingModelsDedupesAndPreservesOrder() {
        #expect(SettingsProvidersView.mergingModels(["a", "b"], adding: ["b", " c ", "", "a", "d"]) == ["a", "b", "c", "d"])
        #expect(SettingsProvidersView.mergingModels([], adding: []) == [])
    }
}
