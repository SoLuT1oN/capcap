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
}
