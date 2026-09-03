import Foundation

/// Errors raised while preparing a request shared by OpenAI-compatible APIs.
/// The caller maps these stable categories to its own user-facing errors.
enum OpenAICompatibleChatTransportError: Error, Equatable {
    case missingAPIKey
    case invalidEndpoint
    case invalidRequestBody
}

/// Minimal request builder and injectable URLSession boundary for
/// OpenAI-compatible Chat Completions APIs.
struct OpenAICompatibleChatTransport {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let dataLoader: DataLoader

    init(dataLoader: @escaping DataLoader = { request in
        try await URLSession.shared.data(for: request)
    }) {
        self.dataLoader = dataLoader
    }

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await dataLoader(request)
    }

    static func makeRequest(
        endpoint: String,
        apiKey: String,
        body: [String: Any],
        timeout: TimeInterval = 60
    ) throws -> URLRequest {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw OpenAICompatibleChatTransportError.invalidRequestBody
        }
        return try makeRequest(endpoint: endpoint, apiKey: apiKey, body: data, timeout: timeout)
    }

    static func makeRequest(
        endpoint: String,
        apiKey: String,
        body: Data,
        timeout: TimeInterval = 60
    ) throws -> URLRequest {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw OpenAICompatibleChatTransportError.missingAPIKey
        }

        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedEndpoint),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw OpenAICompatibleChatTransportError.invalidEndpoint
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return request
    }

    static func buildRequest(
        endpoint: String,
        apiKey: String,
        body: [String: Any],
        timeout: TimeInterval = 60
    ) throws -> URLRequest {
        try makeRequest(endpoint: endpoint, apiKey: apiKey, body: body, timeout: timeout)
    }
}

typealias OpenAICompatibleChatRequestBuilder = OpenAICompatibleChatTransport
typealias OpenAICompatibleRequestBuilder = OpenAICompatibleChatTransport
