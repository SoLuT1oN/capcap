import Foundation

struct AICalendarConfig: Codable, Equatable {
    static let defaultEndpoint = "http://aigw-api.cmsrservice.com/v1/chat/completions"
    static let defaultModel = "GLM-5.3-Flash"

    var endpoint: String
    var apiKey: String
    var model: String
    var workCalendarIdentifier: String
    var personalCalendarIdentifier: String

    init(
        endpoint: String = AICalendarConfig.defaultEndpoint,
        apiKey: String = "",
        model: String = AICalendarConfig.defaultModel,
        workCalendarIdentifier: String = "",
        personalCalendarIdentifier: String = ""
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.workCalendarIdentifier = workCalendarIdentifier
        self.personalCalendarIdentifier = personalCalendarIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? Self.defaultEndpoint
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.defaultModel
        workCalendarIdentifier = try container.decodeIfPresent(String.self, forKey: .workCalendarIdentifier) ?? ""
        personalCalendarIdentifier = try container.decodeIfPresent(String.self, forKey: .personalCalendarIdentifier) ?? ""
    }

    /// Normalizes values at the persistence boundary and restores the shipped
    /// defaults for optional endpoint/model overrides.
    func normalized() -> AICalendarConfig {
        AICalendarConfig(
            endpoint: trimmed(endpoint).isEmpty ? Self.defaultEndpoint : trimmed(endpoint),
            apiKey: trimmed(apiKey),
            model: trimmed(model).isEmpty ? Self.defaultModel : trimmed(model),
            workCalendarIdentifier: trimmed(workCalendarIdentifier),
            personalCalendarIdentifier: trimmed(personalCalendarIdentifier)
        )
    }

    static func load(from defaults: UserDefaults = .standard) -> AICalendarConfig {
        AICalendarConfigStore.load(from: defaults)
    }

    func save(to defaults: UserDefaults = .standard) {
        AICalendarConfigStore.save(self, to: defaults)
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint
        case apiKey
        case model
        case workCalendarIdentifier
        case personalCalendarIdentifier
    }
}

enum AICalendarConfigStore {
    static let storageKey = "aiCalendar.config"

    static func load(from defaults: UserDefaults = .standard) -> AICalendarConfig {
        guard let data = defaults.data(forKey: storageKey),
              let config = try? JSONDecoder().decode(AICalendarConfig.self, from: data) else {
            return AICalendarConfig()
        }
        return config.normalized()
    }

    static func save(_ config: AICalendarConfig, to defaults: UserDefaults = .standard) {
        let normalized = config.normalized()
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
