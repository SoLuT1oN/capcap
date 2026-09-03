import Foundation

/// Maps stable AI Calendar error categories to localized, sanitized UI copy.
/// Never surface provider response bodies, request headers, image data, API
/// keys, calendar contents, or an arbitrary NSError description here.
enum AICalendarErrorMessages {
    static func message(for error: Error) -> String {
        if let serviceError = error as? AICalendarServiceError {
            return serviceError.localizedDescription
        }
        if let calendarError = error as? CalendarEventServiceError {
            return calendarError.localizedDescription
        }
        if let transportError = error as? OpenAICompatibleChatTransportError {
            switch transportError {
            case .missingAPIKey:
                return L10n.aiCalendarMissingAPIKey
            case .invalidEndpoint:
                return L10n.aiCalendarInvalidEndpoint
            case .invalidRequestBody:
                return L10n.aiCalendarInvalidRequest
            }
        }
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
                ? L10n.aiCalendarRequestTimedOut
                : L10n.aiCalendarNetworkError
        }
        return L10n.aiCalendarInvalidRequest
    }
}
