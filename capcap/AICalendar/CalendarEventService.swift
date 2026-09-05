import EventKit
import Foundation

/// The subset of EventKit authorization states that matters to calendar
/// creation. Keeping this separate from EventKit makes the save workflow
/// straightforward to test without touching the user's calendars.
enum CalendarAuthorizationStatus: Equatable {
    case notDetermined
    case restricted
    case denied
    case authorized
    case writeOnly
    case unknown
}

struct CalendarDescriptor: Equatable, Hashable, Identifiable {
    let identifier: String
    let title: String
    let allowsContentModifications: Bool
    let sourceTitle: String

    init(
        identifier: String,
        title: String,
        allowsContentModifications: Bool,
        sourceTitle: String = ""
    ) {
        self.identifier = identifier
        self.title = title
        self.allowsContentModifications = allowsContentModifications
        self.sourceTitle = sourceTitle
    }

    var id: String { identifier }

    /// Calendar titles are not unique across accounts. When the picker has
    /// duplicates, include the EventKit source plus a short stable identifier
    /// suffix so the user can choose the exact writable calendar.
    func pickerTitle(disambiguatingAmong calendars: [CalendarDescriptor]) -> String {
        guard calendars.filter({ $0.title == title }).count > 1 else { return title }
        let source = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(identifier.suffix(6))
        return [title, source, suffix].filter { !$0.isEmpty }.joined(separator: " — ")
    }
}

/// A value object passed to the EventKit adapter. Alarms are optional and
/// always fire at the event start; all-day and recurrence remain unsupported.
struct CalendarEventRecord: Equatable {
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String
    let notes: String
    let url: URL?
    let calendarIdentifier: String
    let allDay: Bool
    let hasAlarms: Bool
    let hasRecurrenceRules: Bool
}

protocol CalendarEventStoreProtocol: AnyObject {
    var authorizationStatus: CalendarAuthorizationStatus { get }

    func requestFullAccessToEvents() async throws -> Bool
    func eventCalendars() -> [CalendarDescriptor]
    func save(_ record: CalendarEventRecord, to calendar: CalendarDescriptor) throws
}

enum CalendarEventStoreError: Error, Equatable, LocalizedError {
    case calendarNotFound
    case calendarNotWritable
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .calendarNotFound:
            return L10n.aiCalendarCalendarNotFound
        case .calendarNotWritable:
            return L10n.aiCalendarCalendarNotWritable
        case .saveFailed:
            return L10n.aiCalendarSaveFailed
        }
    }
}

enum CalendarEventServiceError: Error, Equatable, LocalizedError {
    case accessDenied
    case accessRestricted
    case accessRequiresFullAccess
    case accessUnavailable
    case accessRequestFailed
    case calendarTypeRequiresSelection
    case noWritableCalendars(type: AICalendarType)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return L10n.aiCalendarCalendarAccessDenied
        case .accessRestricted:
            return L10n.aiCalendarCalendarAccessRestricted
        case .accessRequiresFullAccess:
            return L10n.aiCalendarFullAccessRequired
        case .accessUnavailable:
            return L10n.aiCalendarCalendarAccessUnavailable
        case .accessRequestFailed:
            return L10n.aiCalendarCalendarAccessRequestFailed
        case .calendarTypeRequiresSelection:
            return L10n.aiCalendarMissingCalendar
        case .noWritableCalendars:
            return L10n.aiCalendarNoWritableCalendar
        }
    }
}

enum CalendarResolution: Equatable {
    case selected(CalendarDescriptor)
    case requiresSelection(type: AICalendarType, calendars: [CalendarDescriptor])
}

struct CalendarEventSubmission: Equatable {
    let event: AICalendarEventDraft
    let calendar: CalendarDescriptor
    let reminderEnabled: Bool

    init(event: AICalendarEventDraft, calendar: CalendarDescriptor, reminderEnabled: Bool = false) {
        self.event = event
        self.calendar = calendar
        self.reminderEnabled = reminderEnabled
    }
}

enum CalendarEventSaveFailureReason: Equatable {
    case missingTitle
    case missingStart
    case missingEnd
    case endNotAfterStart
    case accessNotGranted
    case accessDenied
    case accessRestricted
    case accessRequiresFullAccess
    case accessUnavailable
    case calendarTypeRequiresSelection
    case calendarNotWritable
    case calendarNotFound
    case saveFailed

    var userMessage: String {
        switch self {
        case .missingTitle:
            return L10n.aiCalendarMissingTitle
        case .missingStart:
            return L10n.aiCalendarMissingStart
        case .missingEnd:
            return L10n.aiCalendarMissingEnd
        case .endNotAfterStart:
            return L10n.aiCalendarInvalidRange
        case .accessNotGranted:
            return L10n.aiCalendarAccessNotGranted
        case .accessDenied:
            return L10n.aiCalendarCalendarAccessDenied
        case .accessRestricted:
            return L10n.aiCalendarCalendarAccessRestricted
        case .accessRequiresFullAccess:
            return L10n.aiCalendarFullAccessRequired
        case .accessUnavailable:
            return L10n.aiCalendarCalendarAccessUnavailable
        case .calendarTypeRequiresSelection:
            return L10n.aiCalendarMissingCalendar
        case .calendarNotWritable:
            return L10n.aiCalendarCalendarNotWritable
        case .calendarNotFound:
            return L10n.aiCalendarCalendarNotFound
        case .saveFailed:
            return L10n.aiCalendarSaveFailed
        }
    }
}

struct CalendarEventSaveFailure: Equatable {
    let index: Int
    let eventTitle: String
    let reason: CalendarEventSaveFailureReason
}

struct CalendarEventSaveSuccess: Equatable {
    let index: Int
    let eventTitle: String
    let calendarTitle: String
}

struct CalendarEventSaveResult: Equatable {
    let successes: [CalendarEventSaveSuccess]
    let failures: [CalendarEventSaveFailure]

    var successCount: Int { successes.count }
    var failureCount: Int { failures.count }
}

/// Resolves the user's Work/Personal mapping and writes confirmed events.
///
/// Permission is deliberately requested only through `ensureFullAccess`, which
/// the editor calls after the user presses Add to Calendar. Constructing this
/// service or launching capcap does not prompt for Calendar access.
final class CalendarEventService {
    private let store: CalendarEventStoreProtocol
    private let defaults: UserDefaults
    private(set) var configuration: AICalendarConfig
    private var accessRequestAttempted = false
    private var hasFullAccess = false

    init(
        store: CalendarEventStoreProtocol,
        configuration: AICalendarConfig? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.defaults = defaults
        self.configuration = (configuration ?? AICalendarConfig.load(from: defaults)).normalized()
    }

    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            store: EventKitCalendarEventStore(),
            defaults: defaults
        )
    }

    /// Requests macOS 14+ Calendar Full Access at the point of first use.
    /// A denial or a write-only grant is remembered for this service instance
    /// so repeated UI actions do not repeatedly present the system prompt.
    func ensureFullAccess() async throws {
        if hasFullAccess || store.authorizationStatus == .authorized {
            hasFullAccess = true
            return
        }

        switch store.authorizationStatus {
        case .restricted:
            throw CalendarEventServiceError.accessRestricted
        case .denied:
            throw CalendarEventServiceError.accessDenied
        case .writeOnly:
            throw CalendarEventServiceError.accessRequiresFullAccess
        case .unknown:
            throw CalendarEventServiceError.accessUnavailable
        case .authorized:
            hasFullAccess = true
        case .notDetermined:
            guard !accessRequestAttempted else {
                throw CalendarEventServiceError.accessDenied
            }
            accessRequestAttempted = true
            do {
                let granted = try await store.requestFullAccessToEvents()
                guard granted else { throw CalendarEventServiceError.accessDenied }
                hasFullAccess = true
            } catch let error as CalendarEventServiceError {
                throw error
            } catch {
                throw CalendarEventServiceError.accessRequestFailed
            }
        }
    }

    /// Resolves a category to a concrete writable calendar.
    ///
    /// A stored identifier is preferred because calendar titles are not unique.
    /// If it has disappeared or is no longer writable, exact title matching is
    /// attempted. Ambiguous and missing matches are returned to the caller for
    /// an explicit picker decision; no arbitrary calendar is selected.
    func resolveCalendar(for type: AICalendarType) throws -> CalendarResolution {
        guard type != .unknown else {
            throw CalendarEventServiceError.calendarTypeRequiresSelection
        }

        let writableCalendars = store.eventCalendars().filter {
            !$0.identifier.isEmpty && $0.allowsContentModifications
        }

        if let storedIdentifier = storedIdentifier(for: type) {
            if let stored = writableCalendars.first(where: { $0.identifier == storedIdentifier }) {
                return .selected(stored)
            }

            // Calendar identifiers can disappear after a sync or become
            // read-only. Remove the stale mapping before asking the user to
            // choose again so we do not keep retrying a dead calendar.
            clearIdentifier(for: type)
        }

        let defaultTitle = type == .work ? "工作" : "个人"
        let titleMatches = writableCalendars.filter { $0.title == defaultTitle }
        if titleMatches.count == 1, let match = titleMatches.first {
            remember(match, for: type)
            return .selected(match)
        }
        if !titleMatches.isEmpty {
            return .requiresSelection(type: type, calendars: titleMatches)
        }
        guard !writableCalendars.isEmpty else {
            throw CalendarEventServiceError.noWritableCalendars(type: type)
        }
        return .requiresSelection(type: type, calendars: writableCalendars)
    }

    /// Persists an explicit picker choice after checking that it is still a
    /// writable calendar exposed by the current EventKit store.
    @discardableResult
    func remember(_ calendar: CalendarDescriptor, for type: AICalendarType) -> Bool {
        guard type != .unknown, calendar.allowsContentModifications else { return false }
        guard store.eventCalendars().contains(where: {
            $0.identifier == calendar.identifier && $0.allowsContentModifications
        }) else {
            return false
        }
        switch type {
        case .work:
            configuration.workCalendarIdentifier = calendar.identifier
        case .personal:
            configuration.personalCalendarIdentifier = calendar.identifier
        case .unknown:
            return false
        }
        configuration = configuration.normalized()
        configuration.save(to: defaults)
        return true
    }

    /// Saves each selected event independently so one EventKit error does not
    /// hide successful events from the user.
    func save(events: [CalendarEventSubmission]) -> CalendarEventSaveResult {
        if let accessFailure = saveAccessFailureReason {
            let failures = events.enumerated().map { index, submission in
                CalendarEventSaveFailure(
                    index: index,
                    eventTitle: submission.event.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    reason: accessFailure
                )
            }
            return CalendarEventSaveResult(successes: [], failures: failures)
        }

        let currentCalendars = store.eventCalendars()
        var successes: [CalendarEventSaveSuccess] = []
        var failures: [CalendarEventSaveFailure] = []

        for (index, submission) in events.enumerated() {
            let title = submission.event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason = validationFailure(for: submission.event) {
                failures.append(CalendarEventSaveFailure(index: index, eventTitle: title, reason: reason))
                continue
            }
            guard submission.event.calendarType != .unknown else {
                failures.append(
                    CalendarEventSaveFailure(
                        index: index,
                        eventTitle: title,
                        reason: .calendarTypeRequiresSelection
                    )
                )
                continue
            }
            guard submission.calendar.allowsContentModifications else {
                failures.append(
                    CalendarEventSaveFailure(index: index, eventTitle: title, reason: .calendarNotWritable)
                )
                continue
            }
            guard let currentCalendar = currentCalendars.first(where: {
                $0.identifier == submission.calendar.identifier
            }) else {
                failures.append(
                    CalendarEventSaveFailure(index: index, eventTitle: title, reason: .calendarNotFound)
                )
                continue
            }
            guard currentCalendar.allowsContentModifications else {
                failures.append(
                    CalendarEventSaveFailure(index: index, eventTitle: title, reason: .calendarNotWritable)
                )
                continue
            }

            guard let start = submission.event.start, let end = submission.event.end else {
                // validationFailure above handles this. Keep the guard local so
                // a future change cannot construct a record with missing dates.
                failures.append(
                    CalendarEventSaveFailure(index: index, eventTitle: title, reason: .missingStart)
                )
                continue
            }

            let record = CalendarEventRecord(
                title: title,
                startDate: start,
                endDate: end,
                location: submission.event.location.trimmingCharacters(in: .whitespacesAndNewlines),
                notes: notesWithAttendees(for: submission.event),
                url: submission.event.url,
                calendarIdentifier: currentCalendar.identifier,
                allDay: false,
                hasAlarms: submission.reminderEnabled,
                hasRecurrenceRules: false
            )

            do {
                try store.save(record, to: currentCalendar)
                remember(currentCalendar, for: submission.event.calendarType)
                successes.append(
                    CalendarEventSaveSuccess(
                        index: index,
                        eventTitle: title,
                        calendarTitle: currentCalendar.title
                    )
                )
            } catch let error as CalendarEventStoreError {
                failures.append(
                    CalendarEventSaveFailure(
                        index: index,
                        eventTitle: title,
                        reason: failureReason(for: error)
                    )
                )
            } catch {
                failures.append(
                    CalendarEventSaveFailure(
                        index: index,
                        eventTitle: title,
                        reason: .saveFailed
                    )
                )
            }
        }

        return CalendarEventSaveResult(successes: successes, failures: failures)
    }

    private func storedIdentifier(for type: AICalendarType) -> String? {
        let value: String
        switch type {
        case .work:
            value = configuration.workCalendarIdentifier
        case .personal:
            value = configuration.personalCalendarIdentifier
        case .unknown:
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var saveAccessFailureReason: CalendarEventSaveFailureReason? {
        switch store.authorizationStatus {
        case .authorized:
            return nil
        case .notDetermined:
            return .accessNotGranted
        case .denied:
            return .accessDenied
        case .restricted:
            return .accessRestricted
        case .writeOnly:
            return .accessRequiresFullAccess
        case .unknown:
            return .accessUnavailable
        }
    }

    private func clearIdentifier(for type: AICalendarType) {
        switch type {
        case .work:
            configuration.workCalendarIdentifier = ""
        case .personal:
            configuration.personalCalendarIdentifier = ""
        case .unknown:
            return
        }
        configuration = configuration.normalized()
        configuration.save(to: defaults)
    }

    private func validationFailure(for event: AICalendarEventDraft) -> CalendarEventSaveFailureReason? {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return .missingTitle }
        guard let start = event.start else { return .missingStart }
        guard let end = event.end else { return .missingEnd }
        guard start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite else {
            return .endNotAfterStart
        }
        guard end > start else { return .endNotAfterStart }
        return nil
    }

    private func failureReason(for error: CalendarEventStoreError) -> CalendarEventSaveFailureReason {
        switch error {
        case .calendarNotFound:
            return .calendarNotFound
        case .calendarNotWritable:
            return .calendarNotWritable
        case .saveFailed:
            return .saveFailed
        }
    }

    private func notesWithAttendees(for event: AICalendarEventDraft) -> String {
        let notes = event.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let attendees = event.attendees.compactMap { attendee -> String? in
            let name = attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = attendee.email.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty && email.isEmpty { return nil }
            if name.isEmpty { return email }
            if email.isEmpty { return name }
            return "\(name) \(email)"
        }
        guard !attendees.isEmpty else { return notes }

        let attendeeNotes = ([L10n.aiCalendarAttendees] + attendees).joined(separator: "\n")
        if notes.isEmpty { return attendeeNotes }
        return "\(notes)\n\n\(attendeeNotes)"
    }
}

/// EventKit's attendees property is read-only on macOS and third-party code
/// cannot construct EKParticipant values for a new event. We therefore append
/// attendee details to notes; this preserves the extracted data without using
/// private APIs and does not send calendar invitations.
final class EventKitCalendarEventStore: CalendarEventStoreProtocol {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    var authorizationStatus: CalendarAuthorizationStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .fullAccess:
            return .authorized
        case .writeOnly:
            return .writeOnly
        @unknown default:
            return .unknown
        }
    }

    func requestFullAccessToEvents() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func eventCalendars() -> [CalendarDescriptor] {
        eventStore.calendars(for: .event).map {
            CalendarDescriptor(
                identifier: $0.calendarIdentifier,
                title: $0.title,
                allowsContentModifications: $0.allowsContentModifications,
                sourceTitle: $0.source.title
            )
        }
    }

    func save(_ record: CalendarEventRecord, to calendar: CalendarDescriptor) throws {
        guard let eventCalendar = eventStore.calendar(withIdentifier: calendar.identifier) else {
            throw CalendarEventStoreError.calendarNotFound
        }
        guard eventCalendar.allowsContentModifications else {
            throw CalendarEventStoreError.calendarNotWritable
        }

        let event = makeEvent(from: record, calendar: eventCalendar)
        do {
            try eventStore.save(event, span: .thisEvent)
        } catch {
            // Provider errors can contain private account or calendar details.
            throw CalendarEventStoreError.saveFailed
        }
    }

    /// Builds the event without persisting it or requesting calendar access.
    func makeEvent(from record: CalendarEventRecord, calendar eventCalendar: EKCalendar) -> EKEvent {
        let event = EKEvent(eventStore: eventStore)
        event.calendar = eventCalendar
        event.title = record.title
        event.startDate = record.startDate
        event.endDate = record.endDate
        event.location = record.location.isEmpty ? nil : record.location
        event.notes = record.notes.isEmpty ? nil : record.notes
        event.url = record.url

        // EventKit's attendee list is read-only, so participants stay in notes.
        // A relative alarm follows any later edit to the event's start time.
        event.isAllDay = false
        event.alarms = record.hasAlarms ? [EKAlarm(relativeOffset: 0)] : nil
        event.recurrenceRules = nil

        return event
    }
}
