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
