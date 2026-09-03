import Foundation

enum AICalendarType: String, Codable, CaseIterable {
    case work
    case personal
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .unknown
            return
        }
        guard let raw = try? container.decode(String.self) else {
            throw AICalendarModelError.invalidCalendarType
        }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["work", "personal", "unknown"].contains(normalized) else {
            throw AICalendarModelError.invalidCalendarType
        }
        self = AICalendarType(rawValue: normalized) ?? .unknown
    }
}

enum AICalendarModelError: Error, Equatable {
    case invalidCalendarType
    case invalidDate
}

struct AICalendarAttendeeDTO: Codable, Equatable {
    var name: String?
    var email: String?

    init(name: String? = nil, email: String? = nil) {
        self.name = name
        self.email = email
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try? container.decode(String.self, forKey: .name)
        email = try? container.decode(String.self, forKey: .email)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case email
    }
}

struct AICalendarAttendee: Codable, Equatable {
    var name: String
    var email: String

    init(name: String = "", email: String = "") {
        self.name = name
        self.email = email
    }

    var displayName: String {
        if !name.isEmpty && !email.isEmpty { return "\(name) <\(email)>" }
        return name.isEmpty ? email : name
    }
}

struct AICalendarEventDTO: Codable, Equatable {
    var title: String?
    var calendarType: String?
    var start: String?
    var end: String?
    var location: String?
    var notes: String?
    var url: String?
    var attendees: [AICalendarAttendeeDTO]?
    var requiresConfirmation: Bool?
    var uncertainFields: [String]?
    var confidence: Double?

    init(
        title: String? = nil,
        calendarType: String? = nil,
        start: String? = nil,
        end: String? = nil,
        location: String? = nil,
        notes: String? = nil,
        url: String? = nil,
        attendees: [AICalendarAttendeeDTO]? = nil,
        requiresConfirmation: Bool? = nil,
        uncertainFields: [String]? = nil,
        confidence: Double? = nil
    ) {
        self.title = title
        self.calendarType = calendarType
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
        self.url = url
        self.attendees = attendees
        self.requiresConfirmation = requiresConfirmation
        self.uncertainFields = uncertainFields
        self.confidence = confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try? container.decode(String.self, forKey: .title)
        calendarType = try? container.decode(String.self, forKey: .calendarType)
        start = try? container.decode(String.self, forKey: .start)
        end = try? container.decode(String.self, forKey: .end)
        location = try? container.decode(String.self, forKey: .location)
        notes = try? container.decode(String.self, forKey: .notes)
        url = try? container.decode(String.self, forKey: .url)
        attendees = try? container.decode([AICalendarAttendeeDTO].self, forKey: .attendees)
        requiresConfirmation = try? container.decode(Bool.self, forKey: .requiresConfirmation)
        uncertainFields = try? container.decode([String].self, forKey: .uncertainFields)
        confidence = try? container.decode(Double.self, forKey: .confidence)
    }

    enum CodingKeys: String, CodingKey {
        case title
        case calendarType = "calendar_type"
        case start
        case end
        case location
        case notes
        case url
        case attendees
        case requiresConfirmation = "requires_confirmation"
        case uncertainFields = "uncertain_fields"
        case confidence
    }
}

struct AICalendarResponseDTO: Codable, Equatable {
    var events: [AICalendarEventDTO]

    init(events: [AICalendarEventDTO] = []) {
        self.events = events
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = try container.decode([AICalendarEventDTO].self, forKey: .events)
    }

    enum CodingKeys: String, CodingKey {
        case events
    }
}

enum AICalendarDraftValidationError: String, Codable, Equatable {
    case missingTitle
    case missingStart
    case missingEnd
    case endNotAfterStart
}

struct AICalendarEventDraft: Codable, Equatable {
    var title: String
    var calendarType: AICalendarType
    var start: Date?
    var end: Date?
    var location: String
    var notes: String
    var url: URL?
    var attendees: [AICalendarAttendee]
    var requiresConfirmation: Bool
    var uncertainFields: [String]
    var confidence: Double?
    var validationError: AICalendarDraftValidationError?

    init(
        title: String = "",
        calendarType: AICalendarType = .unknown,
        start: Date? = nil,
        end: Date? = nil,
        location: String = "",
        notes: String = "",
        url: URL? = nil,
        attendees: [AICalendarAttendee] = [],
        requiresConfirmation: Bool = true,
        uncertainFields: [String] = [],
        confidence: Double? = nil,
        validationError: AICalendarDraftValidationError? = nil
    ) {
        self.title = title
        self.calendarType = calendarType
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
        self.url = url
        self.attendees = attendees
        self.requiresConfirmation = requiresConfirmation
        self.uncertainFields = uncertainFields
        self.confidence = confidence
        self.validationError = validationError
    }

    init(dto: AICalendarEventDTO) throws {
        let title = Self.clean(dto.title)
        let typeRaw = Self.clean(dto.calendarType)
        let calendarType: AICalendarType
        if typeRaw.isEmpty {
            calendarType = .unknown
        } else {
            let normalized = typeRaw.lowercased()
            guard ["work", "personal", "unknown"].contains(normalized) else {
                throw AICalendarModelError.invalidCalendarType
            }
            calendarType = AICalendarType(rawValue: normalized) ?? .unknown
        }

        let startRaw = Self.cleanOptional(dto.start)
        let endRaw = Self.cleanOptional(dto.end)
        let parsedStart = try Self.parseDate(startRaw)
        var parsedEnd: Date?
        var uncertain = Self.normalizedUncertainFields(dto.uncertainFields)
        var needsConfirmation = dto.requiresConfirmation ?? false

        if let parsedStart {
            if let endRaw {
                parsedEnd = try Self.parseDate(endRaw)
                if parsedEnd == nil { Self.append("end", to: &uncertain); needsConfirmation = true }
            } else {
                parsedEnd = parsedStart.addingTimeInterval(60 * 60)
            }
        } else {
            parsedEnd = nil
            Self.append("start", to: &uncertain)
            Self.append("end", to: &uncertain)
            needsConfirmation = true
        }

        var safeURL: URL?
        if let rawURL = Self.cleanOptional(dto.url) {
            if let candidate = URL(string: rawURL),
               let scheme = candidate.scheme?.lowercased(),
               ["http", "https"].contains(scheme),
               candidate.host != nil {
                safeURL = candidate
            } else {
                Self.append("url", to: &uncertain)
                needsConfirmation = true
            }
        }

        var validationError: AICalendarDraftValidationError?
        if title.isEmpty {
            validationError = .missingTitle
        } else if parsedStart == nil {
            validationError = .missingStart
        } else if parsedEnd == nil {
            validationError = .missingEnd
        } else if let parsedEnd, let parsedStart, parsedEnd <= parsedStart {
            validationError = .endNotAfterStart
            needsConfirmation = true
            Self.append("end", to: &uncertain)
        }

        let attendees = (dto.attendees ?? []).compactMap { value -> AICalendarAttendee? in
            let attendee = AICalendarAttendee(
                name: Self.clean(value.name),
                email: Self.clean(value.email)
            )
            return attendee.name.isEmpty && attendee.email.isEmpty ? nil : attendee
        }

        self.init(
            title: title,
            calendarType: calendarType,
            start: parsedStart,
            end: parsedEnd,
            location: Self.clean(dto.location),
            notes: Self.clean(dto.notes),
            url: safeURL,
            attendees: attendees,
            requiresConfirmation: needsConfirmation || calendarType == .unknown,
            uncertainFields: uncertain,
            confidence: dto.confidence.map { min(max($0, 0), 1) },
            validationError: validationError
        )
    }

    var isValid: Bool {
        guard !title.isEmpty, let start, let end else { return false }
        return end > start
    }

    var canSave: Bool { isValid }

    private static func parseDate(_ value: String?) throws -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }

        let withoutFraction = ISO8601DateFormatter()
        withoutFraction.formatOptions = [.withInternetDateTime]
        if let date = withoutFraction.date(from: value) { return date }

        // Natural-language or partial dates are treated as uncertain rather
        // than converted into a guessed clock time. ISO-shaped input is a
        // malformed value and should be surfaced to the caller.
        if Self.looksLikeCompleteISODateTime(value) {
            throw AICalendarModelError.invalidDate
        }
        return nil
    }

    private static func looksLikeCompleteISODateTime(_ value: String) -> Bool {
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func clean(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func cleanOptional(_ value: String?) -> String? {
        let cleaned = clean(value)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func normalizedUncertainFields(_ values: [String]?) -> [String] {
        var result: [String] = []
        for value in values ?? [] {
            append(clean(value), to: &result)
        }
        return result
    }

    private static func append(_ value: String, to values: inout [String]) {
        guard !value.isEmpty, !values.contains(value) else { return }
        values.append(value)
    }
}

typealias AICalendarDraft = AICalendarEventDraft
typealias AICalendarEvent = AICalendarEventDraft
typealias AICalendarResponse = AICalendarResponseDTO
