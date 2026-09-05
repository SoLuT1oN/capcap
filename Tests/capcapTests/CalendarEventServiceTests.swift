import EventKit
import Foundation
import XCTest
@testable import capcap

final class CalendarEventServiceTests: XCTestCase {
    func testEventKitReminderUsesZeroOffsetAndFollowsStartDate() throws {
        let store = EKEventStore()
        let adapter = EventKitCalendarEventStore(eventStore: store)
        let calendar = EKCalendar(for: .event, eventStore: store)
        let start = Date(timeIntervalSince1970: 1_000)
        let record = CalendarEventRecord(
            title: "Planning", startDate: start, endDate: start.addingTimeInterval(3_600),
            location: "", notes: "", url: nil, calendarIdentifier: "test",
            allDay: false, hasAlarms: true, hasRecurrenceRules: false
        )

        let event = adapter.makeEvent(from: record, calendar: calendar)

        XCTAssertEqual(event.alarms?.count, 1)
        let alarm = try XCTUnwrap(event.alarms?.first)
        XCTAssertEqual(alarm.relativeOffset, 0)
        XCTAssertNil(alarm.absoluteDate)
        event.startDate = start.addingTimeInterval(600)
        XCTAssertEqual(event.alarms?.first?.relativeOffset, 0)
        XCTAssertNil(event.alarms?.first?.absoluteDate)
        XCTAssertFalse(event.isAllDay)
        XCTAssertTrue(event.recurrenceRules?.isEmpty ?? true)
    }

    func testEventKitReminderOffCreatesNoAlarm() {
        let store = EKEventStore()
        let adapter = EventKitCalendarEventStore(eventStore: store)
        let calendar = EKCalendar(for: .event, eventStore: store)
        let start = Date(timeIntervalSince1970: 1_000)
        let record = CalendarEventRecord(
            title: "Planning", startDate: start, endDate: start.addingTimeInterval(3_600),
            location: "", notes: "", url: nil, calendarIdentifier: "test",
            allDay: false, hasAlarms: false, hasRecurrenceRules: false
        )

        XCTAssertTrue(adapter.makeEvent(from: record, calendar: calendar).alarms?.isEmpty ?? true)
    }

    func testAccessIsRequestedLazilyAndOnlyOnce() async throws {
        let store = FakeCalendarEventStore(
            authorizationStatus: .notDetermined,
            calendars: [CalendarDescriptor(identifier: "work-1", title: "工作", allowsContentModifications: true)]
        )
        store.requestResult = true
        let service = CalendarEventService(store: store)

        try await service.ensureFullAccess()
        try await service.ensureFullAccess()

        XCTAssertEqual(store.requestCount, 1)
        XCTAssertEqual(store.calendarEnumerationCount, 0)
    }

    func testStoredWritableIdentifierWinsOverTitleMatching() throws {
        let store = FakeCalendarEventStore(
            authorizationStatus: .authorized,
            calendars: [
                CalendarDescriptor(identifier: "work-saved", title: "项目", allowsContentModifications: true),
                CalendarDescriptor(identifier: "work-title", title: "工作", allowsContentModifications: true)
            ]
        )
        let config = AICalendarConfig(workCalendarIdentifier: "work-saved")
        let service = CalendarEventService(store: store, configuration: config)

        let resolution = try service.resolveCalendar(for: .work)

        XCTAssertEqual(resolution, .selected(store.calendars[0]))
    }

    func testStaleIdentifierFallsBackToUniqueWritableDefaultTitle() throws {
        let calendar = CalendarDescriptor(identifier: "work-new", title: "工作", allowsContentModifications: true)
        let store = FakeCalendarEventStore(authorizationStatus: .authorized, calendars: [calendar])
        let config = AICalendarConfig(workCalendarIdentifier: "stale-id")
        let defaults = try isolatedDefaults()
        let service = CalendarEventService(store: store, configuration: config, defaults: defaults)

        let resolution = try service.resolveCalendar(for: .work)

        XCTAssertEqual(resolution, .selected(calendar))
        XCTAssertEqual(AICalendarConfig.load(from: defaults).workCalendarIdentifier, "work-new")
    }

    func testDuplicateDefaultTitleRequiresExplicitSelection() throws {
        let calendars = [
            CalendarDescriptor(identifier: "work-1", title: "工作", allowsContentModifications: true),
            CalendarDescriptor(identifier: "work-2", title: "工作", allowsContentModifications: true)
        ]
        let defaults = try isolatedDefaults()
        let service = CalendarEventService(
            store: FakeCalendarEventStore(authorizationStatus: .authorized, calendars: calendars),
            configuration: AICalendarConfig(workCalendarIdentifier: "stale-id"),
            defaults: defaults
        )

        let resolution = try service.resolveCalendar(for: .work)

        XCTAssertEqual(resolution, .requiresSelection(type: .work, calendars: calendars))
        XCTAssertEqual(AICalendarConfig.load(from: defaults).workCalendarIdentifier, "")
    }

    func testDuplicateCalendarPickerTitlesExposeSourceAndStableIdentifierSuffix() {
        let first = CalendarDescriptor(
            identifier: "calendar-icloud-123456",
            title: "工作",
            allowsContentModifications: true,
            sourceTitle: "iCloud"
        )
        let second = CalendarDescriptor(
            identifier: "calendar-exchange-654321",
            title: "工作",
            allowsContentModifications: true,
            sourceTitle: "Exchange"
        )
        let calendars = [first, second]

        let firstTitle = first.pickerTitle(disambiguatingAmong: calendars)
        let secondTitle = second.pickerTitle(disambiguatingAmong: calendars)

        XCTAssertEqual(firstTitle, "工作 — iCloud — 123456")
        XCTAssertEqual(secondTitle, "工作 — Exchange — 654321")
        XCTAssertNotEqual(firstTitle, secondTitle)
    }

    func testReadOnlyDefaultTitleIsNotSelectedOrWritten() throws {
        let readOnly = CalendarDescriptor(identifier: "work-readonly", title: "工作", allowsContentModifications: false)
        let other = CalendarDescriptor(identifier: "personal-1", title: "我的安排", allowsContentModifications: true)
        let defaults = try isolatedDefaults()
        let service = CalendarEventService(
            store: FakeCalendarEventStore(authorizationStatus: .authorized, calendars: [readOnly, other]),
            configuration: AICalendarConfig(workCalendarIdentifier: "work-readonly"),
            defaults: defaults
        )

        let resolution = try service.resolveCalendar(for: .work)

        XCTAssertEqual(resolution, .requiresSelection(type: .work, calendars: [other]))
        XCTAssertEqual(AICalendarConfig.load(from: defaults).workCalendarIdentifier, "")
    }

    func testStaleIdentifierIsClearedWhenNoWritableCalendarExists() throws {
        let defaults = try isolatedDefaults()
        let service = CalendarEventService(
            store: FakeCalendarEventStore(
                authorizationStatus: .authorized,
                calendars: [CalendarDescriptor(identifier: "work-readonly", title: "工作", allowsContentModifications: false)]
            ),
            configuration: AICalendarConfig(workCalendarIdentifier: "stale-id"),
            defaults: defaults
        )

        XCTAssertThrowsError(try service.resolveCalendar(for: .work)) { error in
            XCTAssertEqual(error as? CalendarEventServiceError, .noWritableCalendars(type: .work))
        }
        XCTAssertEqual(AICalendarConfig.load(from: defaults).workCalendarIdentifier, "")
    }

    func testUnknownTypeRequiresCategoryChoice() throws {
        let service = CalendarEventService(
            store: FakeCalendarEventStore(authorizationStatus: .authorized, calendars: [])
        )

        XCTAssertThrowsError(try service.resolveCalendar(for: .unknown)) { error in
            XCTAssertEqual(error as? CalendarEventServiceError, .calendarTypeRequiresSelection)
        }
    }

    func testSaveValidatesFieldsAndEndDate() throws {
        let store = FakeCalendarEventStore(
            authorizationStatus: .authorized,
            calendars: [CalendarDescriptor(identifier: "work-1", title: "工作", allowsContentModifications: true)]
        )
        let service = CalendarEventService(store: store)
        let calendar = store.calendars[0]
        let start = Date(timeIntervalSince1970: 1_000)

        let invalid = AICalendarEventDraft(title: "", calendarType: .work, start: start, end: start)
        let result = service.save(events: [CalendarEventSubmission(event: invalid, calendar: calendar)])

        XCTAssertEqual(result.successCount, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures[0].reason, .missingTitle)
        XCTAssertTrue(store.savedRecords.isEmpty)
    }

    func testBatchSaveKeepsSuccessfulEventsWhenOneSaveFails() throws {
        let calendar = CalendarDescriptor(identifier: "work-1", title: "工作", allowsContentModifications: true)
        let store = FakeCalendarEventStore(authorizationStatus: .authorized, calendars: [calendar])
        store.failOnSaveIndices = [1]
        let service = CalendarEventService(store: store)
        let first = validDraft(title: "项目周会")
        let second = validDraft(title: "客户沟通")

        let result = service.save(events: [
            CalendarEventSubmission(event: first, calendar: calendar),
            CalendarEventSubmission(event: second, calendar: calendar)
        ])

        XCTAssertEqual(result.successCount, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures[0].index, 1)
        XCTAssertEqual(store.savedRecords.map(\.title), ["项目周会"])
    }

    func testAttendeesAreAppendedToNotesWithoutAttemptingEventKitParticipants() throws {
        let calendar = CalendarDescriptor(identifier: "work-1", title: "工作", allowsContentModifications: true)
        let store = FakeCalendarEventStore(authorizationStatus: .authorized, calendars: [calendar])
        let service = CalendarEventService(store: store)
        var draft = validDraft(title: "评审")
        draft.notes = "原始备注"
        draft.attendees = [
            AICalendarAttendee(name: "张三", email: "zhangsan@example.com"),
            AICalendarAttendee(name: "李四", email: "")
        ]

        let result = service.save(events: [CalendarEventSubmission(event: draft, calendar: calendar)])

        XCTAssertEqual(result.successCount, 1)
        let notes = try XCTUnwrap(store.savedRecords.first?.notes)
        XCTAssertTrue(notes.contains("原始备注"))
        XCTAssertTrue(notes.contains(L10n.aiCalendarAttendees))
        XCTAssertTrue(notes.contains("张三 zhangsan@example.com"))
        XCTAssertTrue(notes.contains("李四"))
    }

    func testCalendarEventRecordDoesNotSetUnsupportedEventProperties() throws {
        let calendar = CalendarDescriptor(identifier: "work-1", title: "工作", allowsContentModifications: true)
        let store = FakeCalendarEventStore(authorizationStatus: .authorized, calendars: [calendar])
        let service = CalendarEventService(store: store)

        _ = service.save(events: [CalendarEventSubmission(event: validDraft(title: "一次性会议"), calendar: calendar)])

        let record = try XCTUnwrap(store.savedRecords.first)
        XCTAssertFalse(record.allDay)
        XCTAssertFalse(record.hasAlarms)
        XCTAssertFalse(record.hasRecurrenceRules)
    }

    func testSaveDoesNotCallStoreForAnyNonFullAccessState() {
        let calendar = CalendarDescriptor(identifier: "work-1", title: "工作", allowsContentModifications: true)
        let draft = validDraft(title: "未授权会议")
        let scenarios: [(CalendarAuthorizationStatus, CalendarEventSaveFailureReason)] = [
            (.notDetermined, .accessNotGranted),
            (.denied, .accessDenied),
            (.restricted, .accessRestricted),
            (.writeOnly, .accessRequiresFullAccess),
            (.unknown, .accessUnavailable)
        ]

        for (status, expectedReason) in scenarios {
            let store = FakeCalendarEventStore(authorizationStatus: status, calendars: [calendar])
            let service = CalendarEventService(store: store)
            let result = service.save(events: [CalendarEventSubmission(event: draft, calendar: calendar)])

            XCTAssertEqual(result.successCount, 0, "Unexpected success for \(status)")
            XCTAssertEqual(result.failures.map(\.reason), [expectedReason], "Unexpected reason for \(status)")
            XCTAssertEqual(store.saveAttemptCount, 0, "Store save called for \(status)")
            XCTAssertEqual(store.calendarEnumerationCount, 0, "Calendars enumerated for \(status)")
        }
    }

    func testStoreErrorMapsToStableReasonWithoutExposingLocalizedDescription() {
        let calendar = CalendarDescriptor(identifier: "work-1", title: "工作", allowsContentModifications: true)
        let store = FakeCalendarEventStore(authorizationStatus: .authorized, calendars: [calendar])
        store.saveError = NSError(
            domain: "PrivateEventKitDomain",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "secret calendar provider details"]
        )
        let service = CalendarEventService(store: store)

        let result = service.save(
            events: [CalendarEventSubmission(event: validDraft(title: "保存失败"), calendar: calendar)]
        )

        XCTAssertEqual(result.successCount, 0)
        XCTAssertEqual(result.failures.map(\.reason), [.saveFailed])
        XCTAssertFalse(result.failures[0].reason.userMessage.contains("secret calendar provider details"))
    }

    func testSaveFailureReasonsUseLocalizedMessages() {
        XCTAssertEqual(CalendarEventSaveFailureReason.missingTitle.userMessage, L10n.aiCalendarMissingTitle)
        XCTAssertEqual(CalendarEventSaveFailureReason.missingStart.userMessage, L10n.aiCalendarMissingStart)
        XCTAssertEqual(CalendarEventSaveFailureReason.missingEnd.userMessage, L10n.aiCalendarMissingEnd)
        XCTAssertEqual(CalendarEventSaveFailureReason.endNotAfterStart.userMessage, L10n.aiCalendarInvalidRange)
        XCTAssertEqual(CalendarEventSaveFailureReason.accessDenied.userMessage, L10n.aiCalendarCalendarAccessDenied)
        XCTAssertEqual(CalendarEventSaveFailureReason.calendarNotWritable.userMessage, L10n.aiCalendarCalendarNotWritable)
        XCTAssertEqual(CalendarEventSaveFailureReason.calendarNotFound.userMessage, L10n.aiCalendarCalendarNotFound)
        XCTAssertEqual(CalendarEventSaveFailureReason.saveFailed.userMessage, L10n.aiCalendarSaveFailed)
    }

    func testDeniedAccessIsReportedWithoutEnumeratingCalendars() async {
        let store = FakeCalendarEventStore(authorizationStatus: .denied, calendars: [])
        let service = CalendarEventService(store: store)

        do {
            try await service.ensureFullAccess()
            XCTFail("Expected denied access")
        } catch CalendarEventServiceError.accessDenied {
            XCTAssertEqual(store.calendarEnumerationCount, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func validDraft(title: String) -> AICalendarEventDraft {
        let start = Date(timeIntervalSince1970: 1_000)
        return AICalendarEventDraft(
            title: title,
            calendarType: .work,
            start: start,
            end: start.addingTimeInterval(3_600),
            requiresConfirmation: false
        )
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "CalendarEventServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class FakeCalendarEventStore: CalendarEventStoreProtocol {
    var authorizationStatus: CalendarAuthorizationStatus
    var calendars: [CalendarDescriptor]
    var requestResult = false
    var requestCount = 0
    var calendarEnumerationCount = 0
    var failOnSaveIndices: Set<Int> = []
    var savedRecords: [CalendarEventRecord] = []
    var saveError: Error?
    var saveAttemptCount = 0
    private var saveCount = 0

    init(authorizationStatus: CalendarAuthorizationStatus, calendars: [CalendarDescriptor]) {
        self.authorizationStatus = authorizationStatus
        self.calendars = calendars
    }

    func requestFullAccessToEvents() async throws -> Bool {
        requestCount += 1
        if requestResult {
            authorizationStatus = .authorized
        }
        return requestResult
    }

    func eventCalendars() -> [CalendarDescriptor] {
        calendarEnumerationCount += 1
        return calendars
    }

    func save(_ record: CalendarEventRecord, to calendar: CalendarDescriptor) throws {
        saveAttemptCount += 1
        defer { saveCount += 1 }
        if let saveError {
            throw saveError
        }
        if failOnSaveIndices.contains(saveCount) {
            throw FakeError.saveFailed
        }
        savedRecords.append(record)
    }

    enum FakeError: Error {
        case saveFailed
    }
}
