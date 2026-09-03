import AppKit
import Foundation

enum AICalendarServiceError: Error, Equatable, LocalizedError {
    case invalidEndpoint
    case missingAPIKey
    case invalidModel
    case imageEncodingFailed
    case unauthorized
    case forbidden
    case rateLimited
    case serverError
    case httpError
    case timeout
    case networkError
    case invalidResponse
    case emptyContent
    case invalidJSON
    case invalidCalendarType
    case invalidDate
    case invalidRequest

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return L10n.aiCalendarInvalidEndpoint
        case .missingAPIKey: return L10n.aiCalendarMissingAPIKey
        case .invalidModel, .invalidRequest: return L10n.aiCalendarInvalidRequest
        case .imageEncodingFailed: return L10n.aiCalendarImageEncodingFailed
        case .unauthorized: return L10n.aiCalendarUnauthorized
        case .forbidden: return L10n.aiCalendarForbidden
        case .rateLimited: return L10n.aiCalendarRateLimited
        case .serverError: return L10n.aiCalendarServiceUnavailable
        case .httpError: return L10n.aiCalendarRequestFailed
        case .timeout: return L10n.aiCalendarRequestTimedOut
        case .networkError: return L10n.aiCalendarNetworkError
        case .invalidResponse, .emptyContent, .invalidJSON, .invalidCalendarType, .invalidDate:
            return L10n.aiCalendarInvalidResponse
        }
    }
}

typealias AICalendarError = AICalendarServiceError

struct AICalendarService {
    typealias DataLoader = OpenAICompatibleChatTransport.DataLoader

    let config: AICalendarConfig
    private let transport: OpenAICompatibleChatTransport

    init(
        config: AICalendarConfig,
        dataLoader: @escaping DataLoader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.config = config
        self.transport = OpenAICompatibleChatTransport(dataLoader: dataLoader)
    }

    init(config: AICalendarConfig, loader: @escaping DataLoader) {
        self.init(config: config, dataLoader: loader)
    }

    init(config: AICalendarConfig, transport: OpenAICompatibleChatTransport) {
        self.config = config
        self.transport = transport
    }

    func extract(from image: NSImage) async throws -> [AICalendarEventDraft] {
        let request = try Self.makeRequest(image: image, config: config)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.load(request)
        } catch let error as CancellationError {
            throw error
        } catch let error as URLError {
            if error.code == .timedOut {
                throw AICalendarServiceError.timeout
            }
            throw AICalendarServiceError.networkError
        } catch {
            throw AICalendarServiceError.networkError
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AICalendarServiceError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 401:
            throw AICalendarServiceError.unauthorized
        case 403:
            throw AICalendarServiceError.forbidden
        case 429:
            throw AICalendarServiceError.rateLimited
        case 500..<600:
            throw AICalendarServiceError.serverError
        default:
            throw AICalendarServiceError.httpError
        }

        guard !data.isEmpty else { throw AICalendarServiceError.emptyContent }
        let completion: OpenAICompatibleChatCompletionResponse
        do {
            completion = try JSONDecoder().decode(OpenAICompatibleChatCompletionResponse.self, from: data)
        } catch {
            throw AICalendarServiceError.invalidResponse
        }
        guard let content = completion.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AICalendarServiceError.emptyContent
        }
        return try Self.parse(content: content)
    }

    func analyze(image: NSImage) async throws -> [AICalendarEventDraft] {
        try await extract(from: image)
    }

    func extractEvents(from image: NSImage) async throws -> [AICalendarEventDraft] {
        try await extract(from: image)
    }

    static func parse(content: String) throws -> [AICalendarEventDraft] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AICalendarServiceError.emptyContent }
        let payload = try fencedJSONPayload(from: trimmed)
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AICalendarServiceError.emptyContent
        }
        guard let data = payload.data(using: .utf8) else {
            throw AICalendarServiceError.invalidJSON
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw AICalendarServiceError.invalidJSON
        }
        guard let eventValues = dictionary["events"] as? [Any] else {
            throw AICalendarServiceError.invalidResponse
        }
        for eventValue in eventValues {
            guard let event = eventValue as? [String: Any] else {
                throw AICalendarServiceError.invalidResponse
            }
            if let calendarType = event["calendar_type"],
               !(calendarType is String),
               !(calendarType is NSNull) {
                throw AICalendarServiceError.invalidCalendarType
            }
        }

        let response: AICalendarResponseDTO
        do {
            response = try JSONDecoder().decode(AICalendarResponseDTO.self, from: data)
        } catch let error as AICalendarModelError {
            throw map(error)
        } catch {
            throw AICalendarServiceError.invalidJSON
        }

        do {
            return try response.events.map { try AICalendarEventDraft(dto: $0) }
        } catch let error as AICalendarModelError {
            throw map(error)
        }
    }

    static func parseResponse(_ content: String) throws -> [AICalendarEventDraft] {
        try parse(content: content)
    }

    static func parseJSON(_ content: String) throws -> [AICalendarEventDraft] {
        try parse(content: content)
    }

    static func makeRequest(
        image: NSImage,
        config: AICalendarConfig,
        now: Date = Date(),
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) throws -> URLRequest {
        let endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw AICalendarServiceError.invalidEndpoint
        }

        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw AICalendarServiceError.missingAPIKey }
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AICalendarServiceError.invalidModel }

        let imageURL: String
        do {
            imageURL = try AICalendarImageEncoder.dataURL(from: image)
        } catch {
            throw AICalendarServiceError.imageEncodingFailed
        }

        let messages: [[String: Any]] = [
            [
                "role": "system",
                "content": AICalendarPrompt.make(now: now, calendar: calendar, timeZone: timeZone),
            ],
            [
                "role": "user",
                "content": [
                    ["type": "text", "text": AICalendarPrompt.userText],
                    ["type": "image_url", "image_url": ["url": imageURL]],
                ],
            ],
        ]
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.1,
            "stream": false,
        ]

        do {
            return try OpenAICompatibleChatTransport.makeRequest(
                endpoint: endpoint,
                apiKey: apiKey,
                body: body,
                timeout: 60
            )
        } catch let error as OpenAICompatibleChatTransportError {
            switch error {
            case .missingAPIKey: throw AICalendarServiceError.missingAPIKey
            case .invalidEndpoint: throw AICalendarServiceError.invalidEndpoint
            case .invalidRequestBody: throw AICalendarServiceError.invalidRequest
            }
        }
    }

    static func buildRequest(
        image: NSImage,
        config: AICalendarConfig,
        now: Date = Date(),
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) throws -> URLRequest {
        try makeRequest(image: image, config: config, now: now, calendar: calendar, timeZone: timeZone)
    }

    private static func fencedJSONPayload(from text: String) throws -> String {
        let lines = text.components(separatedBy: .newlines)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first.hasPrefix("```") else {
            return text
        }
        guard lines.count >= 3,
              lines.last?.trimmingCharacters(in: .whitespaces) == "```" else {
            throw AICalendarServiceError.invalidJSON
        }
        let marker = first.lowercased()
        guard marker == "```" || marker == "```json" else {
            throw AICalendarServiceError.invalidJSON
        }
        return lines.dropFirst().dropLast().joined(separator: "\n")
    }

    private static func map(_ error: AICalendarModelError) -> AICalendarServiceError {
        switch error {
        case .invalidCalendarType: return .invalidCalendarType
        case .invalidDate: return .invalidDate
        }
    }
}

struct OpenAICompatibleChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}
