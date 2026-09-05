import AppKit
import XCTest
@testable import capcap

final class AICalendarConfirmationTests: XCTestCase {
    private let writableCalendar = CalendarDescriptor(
        identifier: "calendar-1",
        title: "Work",
        allowsContentModifications: true
    )

    private var validDraft: AICalendarEventDraft {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        return AICalendarEventDraft(
            title: "Planning",
            calendarType: .work,
            start: start,
            end: start.addingTimeInterval(3_600),
            requiresConfirmation: true
        )
    }

    func testValidSelectedEventProducesSubmission() {
        let model = AICalendarConfirmationEventModel(
            draft: validDraft,
            calendar: writableCalendar
        )

        XCTAssertTrue(model.isValid)
        XCTAssertEqual(model.validationErrors, [])
        XCTAssertEqual(model.submission?.calendar, writableCalendar)
        XCTAssertEqual(model.submission?.reminderEnabled, false)
    }

    @MainActor
    func testReminderSwitchesAreIndependentAndReachSavedEvents() throws {
        _ = NSApplication.shared
        let suite = "AICalendarReminderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReminderConfirmationStore(calendar: writableCalendar)
        let controller = AICalendarConfirmationController(
            events: [validDraft, validDraft],
            calendarService: CalendarEventService(store: store, defaults: defaults)
        )
        defer { controller.close() }
        let views = descendants(of: try XCTUnwrap(controller.window?.contentView))
        let switches = views.compactMap { $0 as? NSSwitch }
        XCTAssertEqual(switches.count, 2)
        let first = try XCTUnwrap(switches.first)
        XCTAssertTrue(switches.allSatisfy { $0.state == .off })
        first.state = .on
        first.sendAction(first.action, to: first.target)

        let add = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == L10n.aiCalendarAdd })
        add.performClick(nil)
        XCTAssertEqual(store.records.map(\.hasAlarms), [true, false])
    }

    @MainActor
    func testReminderChoiceSurvivesEditsAndPartialFailureWithoutDuplicateSaves() throws {
        _ = NSApplication.shared
        let suite = "AICalendarReminderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReminderConfirmationStore(calendar: writableCalendar)
        store.failOnAttempt = 2
        let controller = AICalendarConfirmationController(
            events: [validDraft, validDraft],
            calendarService: CalendarEventService(store: store, defaults: defaults)
        )
        defer { controller.close() }
        let views = descendants(of: try XCTUnwrap(controller.window?.contentView))
        let switches = views.compactMap { $0 as? NSSwitch }
        XCTAssertEqual(switches.count, 2)
        guard switches.count == 2 else { return }
        // Turning a reminder back off must not leave an alarm behind.
        switches[0].state = .on
        switches[0].sendAction(switches[0].action, to: switches[0].target)
        switches[0].state = .off
        switches[0].sendAction(switches[0].action, to: switches[0].target)
        switches[1].state = .on
        switches[1].sendAction(switches[1].action, to: switches[1].target)

        let dateFields = views.compactMap { $0 as? NSTextField }.filter {
            $0.placeholderString == L10n.aiCalendarDateTimePlaceholder
        }
        XCTAssertEqual(dateFields.count, 4)
        guard dateFields.count == 4 else { return }
        dateFields[2].stringValue = "2030-01-02 10:00"
        dateFields[3].stringValue = "2030-01-02 11:00"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: dateFields[2]))
        let calendarPickers = views.compactMap { $0 as? NSPopUpButton }.filter {
            $0.selectedItem?.representedObject as? String == writableCalendar.identifier
        }
        let secondCalendar = try XCTUnwrap(calendarPickers.last)
        let otherCalendar = CalendarDescriptor(
            identifier: "calendar-2", title: "Personal", allowsContentModifications: true
        )
        store.additionalCalendars = [otherCalendar]
        let typePicker = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.last {
            $0.selectedItem?.representedObject as? String == AICalendarType.work.rawValue
        })
        typePicker.selectItem(at: typePicker.indexOfItem(withRepresentedObject: AICalendarType.personal.rawValue))
        typePicker.sendAction(typePicker.action, to: typePicker.target)
        secondCalendar.selectItem(at: secondCalendar.indexOfItem(withRepresentedObject: otherCalendar.identifier))
        secondCalendar.sendAction(secondCalendar.action, to: secondCalendar.target)
        XCTAssertEqual(switches[1].state, .on)

        let add = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == L10n.aiCalendarAdd })
        add.performClick(nil)
        XCTAssertEqual(store.records.map(\.hasAlarms), [false])
        XCTAssertFalse(switches[0].isEnabled)
        XCTAssertTrue(switches[1].isEnabled)
        XCTAssertEqual(switches[1].state, .on)

        add.performClick(nil)
        XCTAssertEqual(store.records.map(\.hasAlarms), [false, true])
        XCTAssertEqual(store.attempts, 3)
        let expectedStart = Calendar.current.date(from: DateComponents(year: 2030, month: 1, day: 2, hour: 10))
        XCTAssertEqual(store.records.last?.startDate, expectedStart)
        XCTAssertEqual(store.records.last?.calendarIdentifier, otherCalendar.identifier)
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    func testUnknownTypeWithoutCalendarRequiresSelection() {
        var draft = validDraft
        draft.calendarType = .unknown
        let model = AICalendarConfirmationEventModel(draft: draft)

        XCTAssertFalse(model.isValid)
        XCTAssertTrue(model.validationErrors.contains(.missingCalendar))
    }

    func testMissingAndInvalidTimesRemainInvalid() {
        var missingStart = validDraft
        missingStart.start = nil
        let missingStartModel = AICalendarConfirmationEventModel(
            draft: missingStart,
            calendar: writableCalendar
        )
        XCTAssertTrue(missingStartModel.validationErrors.contains(.missingStart))

        var invalidRange = validDraft
        invalidRange.end = invalidRange.start
        let invalidRangeModel = AICalendarConfirmationEventModel(
            draft: invalidRange,
            calendar: writableCalendar
        )
        XCTAssertTrue(invalidRangeModel.validationErrors.contains(.endNotAfterStart))
    }

    func testReadOnlyCalendarCannotBeSaved() {
        let readOnly = CalendarDescriptor(
            identifier: "calendar-2",
            title: "Work",
            allowsContentModifications: false
        )
        let model = AICalendarConfirmationEventModel(draft: validDraft, calendar: readOnly)

        XCTAssertFalse(model.isValid)
        XCTAssertTrue(model.validationErrors.contains(.calendarNotWritable))
    }

    func testUncheckedEventDoesNotBlockAdd() {
        let model = AICalendarConfirmationEventModel(
            draft: AICalendarEventDraft(),
            included: false
        )

        XCTAssertTrue(model.isValid)
        XCTAssertNil(model.submission)
    }

    func testSingleCardUsesMeasuredContentWithoutScrolling() {
        let result = AICalendarConfirmationSizing.calculate(
            cardsHeight: 180,
            headerHeight: 32,
            footerHeight: 48,
            layoutSpacing: 12,
            verticalInsets: 40,
            maximumContentHeight: 500
        )

        XCTAssertEqual(result.contentHeight, 324, accuracy: 0.001)
        XCTAssertEqual(result.scrollHeight, 180, accuracy: 0.001)
        XCTAssertFalse(result.isScrollable)
    }

    func testTwoCardsIncreaseContentHeightByMeasuredCardGrowth() {
        let singleCard = AICalendarConfirmationSizing.calculate(
            cardsHeight: 180,
            headerHeight: 32,
            footerHeight: 48,
            layoutSpacing: 12,
            verticalInsets: 40,
            maximumContentHeight: 600
        )
        let twoCards = AICalendarConfirmationSizing.calculate(
            cardsHeight: 360,
            headerHeight: 32,
            footerHeight: 48,
            layoutSpacing: 12,
            verticalInsets: 40,
            maximumContentHeight: 600
        )

        XCTAssertGreaterThan(twoCards.contentHeight, singleCard.contentHeight)
        XCTAssertEqual(twoCards.contentHeight - singleCard.contentHeight, 180, accuracy: 0.001)
        XCTAssertEqual(twoCards.scrollHeight, 360, accuracy: 0.001)
        XCTAssertFalse(twoCards.isScrollable)
    }

    func testContentHeightIsCappedAndScrollHeightIsTruncatedWhenCardsExceedMaximum() {
        let result = AICalendarConfirmationSizing.calculate(
            cardsHeight: 900,
            headerHeight: 32,
            footerHeight: 48,
            layoutSpacing: 12,
            verticalInsets: 40,
            maximumContentHeight: 500
        )

        XCTAssertEqual(result.contentHeight, 500, accuracy: 0.001)
        XCTAssertEqual(result.scrollHeight, 356, accuracy: 0.001)
        XCTAssertTrue(result.isScrollable)
    }
}

private final class ReminderConfirmationStore: CalendarEventStoreProtocol {
    let authorizationStatus: CalendarAuthorizationStatus = .authorized
    let calendar: CalendarDescriptor
    var records: [CalendarEventRecord] = []
    var additionalCalendars: [CalendarDescriptor] = []
    var attempts = 0
    var failOnAttempt: Int?

    init(calendar: CalendarDescriptor) { self.calendar = calendar }
    func requestFullAccessToEvents() async throws -> Bool { true }
    func eventCalendars() -> [CalendarDescriptor] { [calendar] + additionalCalendars }
    func save(_ record: CalendarEventRecord, to calendar: CalendarDescriptor) throws {
        attempts += 1
        if attempts == failOnAttempt { throw CalendarEventStoreError.saveFailed }
        records.append(record)
    }
}
