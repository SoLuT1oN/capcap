import Foundation
import XCTest
@testable import capcap

final class AICalendarWorkflowTests: XCTestCase {
    func testFirstBeginSucceedsAndEntersRecognizing() {
        var state = AICalendarWorkflowState()
        let requestID = UUID()

        XCTAssertTrue(state.begin(requestID: requestID))
        XCTAssertEqual(state.phase, .recognizing(requestID))
    }

    func testSecondBeginIsRejectedWhileFirstRequestIsActive() {
        var state = AICalendarWorkflowState()
        let firstRequestID = UUID()
        let secondRequestID = UUID()

        XCTAssertTrue(state.begin(requestID: firstRequestID))
        XCTAssertFalse(state.begin(requestID: secondRequestID))
        XCTAssertEqual(state.phase, .recognizing(firstRequestID))
    }

    func testMatchingRequestMovesFromRecognizingToConfirming() {
        var state = AICalendarWorkflowState()
        let requestID = UUID()

        XCTAssertTrue(state.begin(requestID: requestID))
        XCTAssertTrue(state.markAwaitingConfirmation(requestID: requestID))
        XCTAssertEqual(state.phase, .confirming(requestID))
    }

    func testWrongRequestIDCannotChangeRecognizingOrConfirmingState() {
        var state = AICalendarWorkflowState()
        let requestID = UUID()
        let wrongRequestID = UUID()

        XCTAssertTrue(state.begin(requestID: requestID))
        XCTAssertFalse(state.markAwaitingConfirmation(requestID: wrongRequestID))
        XCTAssertEqual(state.phase, .recognizing(requestID))

        XCTAssertTrue(state.markAwaitingConfirmation(requestID: requestID))
        XCTAssertFalse(state.finish(requestID: wrongRequestID))
        XCTAssertEqual(state.phase, .confirming(requestID))
    }

    func testExpiredRequestIDCannotChangeIdleOrNewRequestState() {
        var state = AICalendarWorkflowState()
        let expiredRequestID = UUID()
        let activeRequestID = UUID()

        XCTAssertTrue(state.begin(requestID: expiredRequestID))
        XCTAssertTrue(state.markAwaitingConfirmation(requestID: expiredRequestID))
        XCTAssertTrue(state.finish(requestID: expiredRequestID))
        XCTAssertEqual(state.phase, .idle)

        XCTAssertFalse(state.markAwaitingConfirmation(requestID: expiredRequestID))
        XCTAssertFalse(state.finish(requestID: expiredRequestID))
        XCTAssertEqual(state.phase, .idle)

        XCTAssertTrue(state.begin(requestID: activeRequestID))
        XCTAssertFalse(state.markAwaitingConfirmation(requestID: expiredRequestID))
        XCTAssertFalse(state.finish(requestID: expiredRequestID))
        XCTAssertEqual(state.phase, .recognizing(activeRequestID))
    }

    func testMatchingRequestFinishesToIdle() {
        var state = AICalendarWorkflowState()
        let requestID = UUID()

        XCTAssertTrue(state.begin(requestID: requestID))
        XCTAssertTrue(state.markAwaitingConfirmation(requestID: requestID))
        XCTAssertTrue(state.finish(requestID: requestID))
        XCTAssertEqual(state.phase, .idle)
    }
}
