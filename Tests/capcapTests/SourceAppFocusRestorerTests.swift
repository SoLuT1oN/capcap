import AppKit
import XCTest
@testable import capcap

@MainActor
final class SourceAppFocusRestorerTests: XCTestCase {
    func testPasteWaitsForFocusAndKeepsClipboardImage() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(Data([1, 2, 3]), forType: .png)
        let originalCount = board.changeCount
        var activePID = ProcessInfo.processInfo.processIdentifier
        var events: [pid_t] = []
        let restorer = SourceAppFocusRestorer(processIdentifier: 123, environment: .init(
            activate: { _ in }, frontmostPID: { activePID },
            isTrusted: { true }, postPaste: { events.append($0) }
        ))
        restorer.pasteCopiedImage(pasteboard: board)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(events.isEmpty)
        activePID = 123
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(events, [123])
        XCTAssertEqual(board.data(forType: .png), Data([1, 2, 3]))
        XCTAssertEqual(board.changeCount, originalCount)
        restorer.pasteCopiedImage(pasteboard: board)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(events, [123], "A completed request must not paste twice")
    }

    func testChangedClipboardCancelsPendingPaste() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(Data([1]), forType: .png)
        var activePID = ProcessInfo.processInfo.processIdentifier
        var events: [pid_t] = []
        let restorer = SourceAppFocusRestorer(processIdentifier: 123, environment: .init(
            activate: { _ in }, frontmostPID: { activePID },
            isTrusted: { true }, postPaste: { events.append($0) }
        ))
        restorer.pasteCopiedImage(pasteboard: board)
        board.clearContents()
        board.setString("new clipboard", forType: .string)
        activePID = 123
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(board.string(forType: .string), "new clipboard")
    }

    func testMissingPermissionOrDifferentApplicationDoesNotPaste() async throws {
        for (trusted, activePID) in [(false, pid_t(123)), (true, pid_t(456))] {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.setData(Data([1]), forType: .png)
            var events: [pid_t] = []
            let restorer = SourceAppFocusRestorer(processIdentifier: 123, environment: .init(
                activate: { _ in }, frontmostPID: { activePID },
                isTrusted: { trusted }, postPaste: { events.append($0) }
            ))
            restorer.pasteCopiedImage(pasteboard: board)
            try await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertTrue(events.isEmpty)
            XCTAssertNotNil(board.data(forType: .png))
        }
    }
}
